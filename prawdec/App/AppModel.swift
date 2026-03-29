//
//  AppModel.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var jobs: [ConversionJob] = []
    var selectedJobID: ConversionJob.ID?
    var defaultOutputDirectoryURL: URL
    var isShowingImporter = false
    var alertMessage: String?

    private let conversionService: ProResRAWConversionService
    private let queueEngine: QueueEngine
    private var queueEventsTask: Task<Void, Never>?
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    init(conversionService: ProResRAWConversionService) {
        self.conversionService = conversionService
        self.queueEngine = QueueEngine(service: conversionService)
        self.defaultOutputDirectoryURL = AppStateStore.loadDefaultOutputDirectoryURL()
        self.jobs = AppStateStore.loadJobs().map(Self.restoredJob)
        self.selectedJobID = jobs.first?.id

        queueEventsTask = Task { [queueEngine] in
            for await event in queueEngine.events {
                self.apply(event)
            }
        }

        for job in jobs where Self.needsRescan(job) {
            scheduleScan(for: job)
        }
    }

    var selectedJob: ConversionJob? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    var isAnyJobActive: Bool {
        jobs.contains(where: { $0.status.isActive || $0.status == .paused })
    }

    var queuedJobCount: Int {
        jobs.filter { $0.status == .queued }.count
    }

    /// Returns 1-based queue position for a queued job, or nil if not queued.
    func queuePosition(for id: UUID) -> Int? {
        let queued = jobs.filter { $0.status == .queued }
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    // MARK: - Computed Properties for Views

    var canCancelAny: Bool {
        jobs.contains(where: { $0.canCancel })
    }

    // MARK: - Job Lifecycle

    func addSourceURLs(_ urls: [URL]) {
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !jobs.contains(where: { $0.sourceURL == standardizedURL }) else { continue }

            let job = ConversionJob(
                sourceURL: standardizedURL,
                outputDirectoryURL: defaultOutputDirectoryURL,
                status: .scanning
            )

            jobs.append(job)
            if selectedJobID == nil {
                selectedJobID = job.id
            }

            scheduleScan(for: job)
        }

        persistJobs()
    }

    func removeSelectedJob() {
        guard let selectedJob else { return }
        remove(jobID: selectedJob.id)
    }

    func remove(jobID: UUID) {
        scanTasks[jobID]?.cancel()
        scanTasks[jobID] = nil

        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]

        if job.status.isActive || job.status == .paused {
            // Active job — ask QueueEngine to cancel and remove
            Task { await queueEngine.cancelAndRemove(id: jobID) }
        } else {
            jobs.remove(at: index)
            if selectedJobID == jobID {
                selectedJobID = jobs.first?.id
            }
            persistJobs()
        }
    }

    // MARK: - Execution Control

    func startAll() {
        for index in jobs.indices {
            switch jobs[index].status {
            case .queued:
                break
            case .failed, .cancelled:
                resetJobForRequeue(at: index)
            default:
                continue
            }
        }
        persistJobs()
        scheduleNextIfPossible()
    }

    func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        switch jobs[index].status {
        case .paused:
            jobs[index].status = .running
            Task { await queueEngine.resume() }
        case .queued:
            scheduleNextIfPossible()
        case .failed, .cancelled:
            resetJobForRequeue(at: index)
            persistJobs()
            scheduleNextIfPossible()
        default:
            break
        }
    }

    func pause(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status == .running || jobs[index].status == .preparing else { return }
        jobs[index].status = .paused
        Task { await queueEngine.pause() }
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        switch jobs[index].status {
        case .preparing, .running, .pausing, .paused:
            jobs[index].status = .cancelling
            Task { await queueEngine.cancel(id: jobID) }
        case .queued:
            jobs[index].status = .cancelled
            jobs[index].finishedAt = .now
            persistJobs()
        case .scanning:
            scanTasks[jobID]?.cancel()
            scanTasks[jobID] = nil
            jobs[index].status = .cancelled
            jobs[index].finishedAt = .now
            persistJobs()
        default:
            break
        }
    }

    func cancelAll() {
        for index in jobs.indices {
            let id = jobs[index].id
            switch jobs[index].status {
            case .preparing, .running, .pausing, .paused:
                jobs[index].status = .cancelling
                Task { await queueEngine.cancel(id: id) }
            case .queued:
                jobs[index].status = .cancelled
                jobs[index].finishedAt = .now
            case .scanning:
                scanTasks[id]?.cancel()
                scanTasks[id] = nil
                jobs[index].status = .cancelled
                jobs[index].finishedAt = .now
            default:
                break
            }
        }
        persistJobs()
    }

    // MARK: - Configuration Updates

    func updateOutputDirectory(_ url: URL, for jobID: UUID) {
        update(jobID: jobID) { $0.outputDirectoryURL = url }
    }

    func updateCompressionKind(_ kind: DNGCompressionKind, for jobID: UUID) {
        update(jobID: jobID) { job in
            job.compressionPreset = job.compressionPreset.updating(kind: kind)
        }
    }

    func updateCompressionQuality(_ quality: Int, for jobID: UUID) {
        update(jobID: jobID) { job in
            job.compressionPreset = job.compressionPreset.updating(quality: quality)
        }
    }

    func chooseOutputDirectory(for jobID: UUID) async {
        let initialURL = jobs.first(where: { $0.id == jobID })?.outputDirectoryURL ?? defaultOutputDirectoryURL
        if let url = await DirectoryPicker.pickDirectory(startingAt: initialURL) {
            updateOutputDirectory(url, for: jobID)
        }
    }

    func revealOutputFolder(for jobID: UUID) {
        guard
            let job = jobs.first(where: { $0.id == jobID }),
            let outputFolderURL = job.outputFolderURL
        else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([outputFolderURL])
    }

    // MARK: - Private Helpers

    private func update(jobID: UUID, mutate: (inout ConversionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].canEditConfiguration else { return }
        mutate(&jobs[index])
        persistJobs()
    }

    private func resetJobForRequeue(at index: Int) {
        jobs[index].status = .queued
        jobs[index].errorMessage = nil
        jobs[index].note = nil
        jobs[index].warnings = []
        jobs[index].finishedAt = nil
        jobs[index].outputFolderURL = nil
        jobs[index].progress = JobProgress(
            completedFrames: 0,
            estimatedTotalFrames: jobs[index].clipMetadata?.estimatedFrameCount,
            startedAt: nil
        )
    }

    /// Picks the next queued job and dispatches it to QueueEngine.
    private func scheduleNextIfPossible() {
        guard let nextJob = jobs.first(where: { $0.status == .queued }) else { return }
        guard let index = jobs.firstIndex(where: { $0.id == nextJob.id }) else { return }

        jobs[index].status = .preparing
        if jobs[index].startedAt == nil {
            jobs[index].startedAt = .now
        }
        jobs[index].finishedAt = nil
        persistJobs()

        let job = jobs[index]
        Task { await queueEngine.execute(job: job) }
    }

    // MARK: - Scan

    private func finishScan(for jobID: UUID, summary: ClipMetadataSummary) {
        scanTasks[jobID] = nil
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].clipMetadata = summary
        jobs[index].status = .queued
        jobs[index].progress.estimatedTotalFrames = summary.estimatedFrameCount
        persistJobs()
    }

    private func failScan(for jobID: UUID, error: Error) {
        scanTasks[jobID] = nil
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = .failed
        jobs[index].errorMessage = error.localizedDescription
        persistJobs()
    }

    // MARK: - Event Handling (from QueueEngine)

    private func apply(_ event: QueueEngineEvent) {
        switch event {
        case .prepared(let id, let outputFolder, let estimatedFrames):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].outputFolderURL = outputFolder
            if let est = estimatedFrames {
                jobs[index].progress.estimatedTotalFrames = est
            }
            if jobs[index].status != .paused {
                jobs[index].status = .running
                if jobs[index].progress.startedAt == nil {
                    jobs[index].progress.startedAt = .now
                }
            }

        case .progress(let id, let completed, let total):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            if jobs[index].status != .paused {
                jobs[index].status = .running
            }
            jobs[index].progress.completedFrames = completed
            if let total {
                jobs[index].progress.estimatedTotalFrames = total
            }

        case .note(let id, let note):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].note = note

        case .warning(let id, let message):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].warnings.append(message)

        case .clipSummary(let id, let summary):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].clipMetadata = summary
            if jobs[index].progress.estimatedTotalFrames == nil {
                jobs[index].progress.estimatedTotalFrames = summary.estimatedFrameCount
            }

        case .finished(let id, let result):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success:
                jobs[index].status = .completed
                jobs[index].finishedAt = .now
                jobs[index].progress.completedFrames =
                    jobs[index].progress.estimatedTotalFrames ?? jobs[index].progress.completedFrames
            case .failure(let error):
                if case ConversionServiceError.cancelled = error {
                    jobs[index].status = .cancelled
                } else {
                    jobs[index].status = .failed
                    jobs[index].errorMessage = error.localizedDescription
                }
                jobs[index].finishedAt = .now
            }
            persistJobs()
            scheduleNextIfPossible()

        case .removed(let id):
            jobs.removeAll { $0.id == id }
            if selectedJobID == id {
                selectedJobID = jobs.first?.id
            }
            persistJobs()
            scheduleNextIfPossible()
        }
    }

    private func scheduleScan(for job: ConversionJob) {
        scanTasks[job.id]?.cancel()
        let sourceURL = job.sourceURL
        let scanTask = Task { [conversionService] in
            do {
                let summary = try await conversionService.scanClipSummary(for: sourceURL)
                self.finishScan(for: job.id, summary: summary)
            } catch {
                self.failScan(for: job.id, error: error)
            }
        }
        scanTasks[job.id] = scanTask
    }

    private func persistJobs() {
        let snapshot = jobs
        Task { await AppStateStore.writer.saveJobs(snapshot) }
    }

    private static func restoredJob(_ persistedJob: ConversionJob) -> ConversionJob {
        var job = persistedJob

        switch job.status {
        case .scanning:
            job.outputFolderURL = nil
            job.progress.completedFrames = 0
            job.startedAt = nil
            job.finishedAt = nil
            break
        case .preparing, .running, .pausing, .paused, .cancelling:
            job.status = job.clipMetadata == nil ? .scanning : .queued
            job.note = L10n.tr("app.job.restored_note")
            job.errorMessage = nil
            job.outputFolderURL = nil
            job.progress.completedFrames = 0
            job.startedAt = nil
            job.finishedAt = nil
        case .queued, .failed, .cancelled, .completed:
            if job.clipMetadata == nil, job.status != .completed {
                job.status = .scanning
                job.outputFolderURL = nil
                job.progress.completedFrames = 0
                job.startedAt = nil
                job.finishedAt = nil
            }
        }

        return job
    }

    private static func needsRescan(_ job: ConversionJob) -> Bool {
        job.status == .scanning || job.clipMetadata == nil
    }

    static func makeDefault() -> AppModel {
        AppModel(conversionService: ProResRAWConversionService())
    }
}
