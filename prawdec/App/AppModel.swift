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
    @ObservationIgnored
    private var _jobs: [ConversionJob] = []

    var jobs: [ConversionJob] {
        get {
            access(keyPath: \.jobs)
            return _jobs
        }
        set {
            withMutation(keyPath: \.jobs) {
                _jobs = newValue
            }
        }
    }

    var selectedJobID: ConversionJob.ID?
    var defaultOutputDirectoryURL: URL
    var isShowingImporter = false
    var alertMessage: String?

    private let conversionService: ProResRAWConversionService
    private let queueEngine: QueueEngine
    private var queueEventsTask: Task<Void, Never>?
    private var scanTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingAutoStartAfterScan: Set<UUID> = []
    @ObservationIgnored
    private var isSchedulingNextJob = false
    @ObservationIgnored
    private var persistenceGeneration: UInt64 = 0

    init(conversionService: ProResRAWConversionService) {
        self.conversionService = conversionService
        self.queueEngine = QueueEngine(service: conversionService)
        self.defaultOutputDirectoryURL = AppStateStore.loadDefaultOutputDirectoryURL()
        self._jobs = AppStateStore.loadJobs().map(Self.restoredJob)
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

    var canCancelAny: Bool {
        jobs.contains(where: { $0.canCancel })
    }

    func queuePosition(for id: UUID) -> Int? {
        let queued = jobs.filter { $0.status == .queued }
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    func addSourceURLs(_ urls: [URL]) {
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard !jobs.contains(where: { $0.sourceURL == standardizedURL }) else { continue }

            let job = ConversionJob(
                sourceURL: standardizedURL,
                configuration: JobConfiguration(
                    outputDirectoryURL: defaultOutputDirectoryURL,
                    compressionPreset: .jpegLossless
                ),
                status: .scanning,
                inspection: nil,
                runState: nil
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
        pendingAutoStartAfterScan.remove(jobID)
        scanTasks[jobID]?.cancel()
        scanTasks[jobID] = nil

        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[index]

        if job.status.isActive || job.status == .paused {
            Task { await queueEngine.cancelAndRemove(id: jobID) }
        } else {
            jobs.remove(at: index)
            if selectedJobID == jobID {
                selectedJobID = jobs.first?.id
            }
            persistJobs()
        }
    }

    func startAll() {
        for index in jobs.indices {
            switch jobs[index].status {
            case .queued:
                break
            case .failed, .cancelled:
                prepareJobForStart(at: index, autostartAfterInspection: true)
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
            prepareJobForStart(at: index, autostartAfterInspection: true)
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
        pendingAutoStartAfterScan.remove(jobID)

        switch jobs[index].status {
        case .preparing, .running, .pausing, .paused:
            jobs[index].status = .cancelling
            Task { await queueEngine.cancel(id: jobID) }
        case .queued:
            jobs[index].status = .cancelled
            jobs[index].runState = nil
            jobs[index].statusNote = nil
            jobs[index].statusErrorMessage = nil
            persistJobs()
        case .scanning:
            scanTasks[jobID]?.cancel()
            scanTasks[jobID] = nil
            jobs[index].status = .cancelled
            jobs[index].statusNote = nil
            jobs[index].statusErrorMessage = nil
            persistJobs()
        default:
            break
        }
    }

    func cancelAll() {
        for index in jobs.indices {
            let id = jobs[index].id
            pendingAutoStartAfterScan.remove(id)
            switch jobs[index].status {
            case .preparing, .running, .pausing, .paused:
                jobs[index].status = .cancelling
                Task { await queueEngine.cancel(id: id) }
            case .queued:
                jobs[index].status = .cancelled
                jobs[index].runState = nil
                jobs[index].statusNote = nil
                jobs[index].statusErrorMessage = nil
            case .scanning:
                scanTasks[id]?.cancel()
                scanTasks[id] = nil
                jobs[index].status = .cancelled
                jobs[index].statusNote = nil
                jobs[index].statusErrorMessage = nil
            default:
                break
            }
        }
        persistJobs()
    }

    func updateOutputDirectory(_ url: URL, for jobID: UUID) {
        update(jobID: jobID) {
            $0.configuration.outputDirectoryURL = url
            $0.runState?.outputFolderURL = nil
        }
    }

    func updateCompressionKind(_ kind: DNGCompressionKind, for jobID: UUID) {
        update(jobID: jobID) { job in
            job.configuration.compressionPreset = job.configuration.compressionPreset.updating(kind: kind)
        }
    }

    func updateCompressionQuality(_ quality: Int, for jobID: UUID) {
        update(jobID: jobID) { job in
            job.configuration.compressionPreset = job.configuration.compressionPreset.updating(quality: quality)
        }
    }

    func updateVideoTimecodeTrack(_ timecodeTrackID: Int32?, for videoTrackID: Int32, in jobID: UUID) {
        update(jobID: jobID) { job in
            job.configuration.setSelectedTimecodeTrackID(timecodeTrackID, for: videoTrackID, kind: .video)
        }
    }

    func updateAudioTimecodeTrack(_ timecodeTrackID: Int32?, for audioTrackID: Int32, in jobID: UUID) {
        update(jobID: jobID) { job in
            job.configuration.setSelectedTimecodeTrackID(timecodeTrackID, for: audioTrackID, kind: .audio)
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

    private func update(jobID: UUID, mutate: (inout ConversionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].canEditConfiguration else { return }
        mutate(&jobs[index])
        jobs[index].configuration.videoTimecodeSelections.sort { $0.mediaTrackID < $1.mediaTrackID }
        jobs[index].configuration.audioTimecodeSelections.sort { $0.mediaTrackID < $1.mediaTrackID }
        persistJobs()
    }

    private func prepareJobForStart(at index: Int, autostartAfterInspection: Bool) {
        let id = jobs[index].id
        jobs[index].runState = nil
        jobs[index].statusNote = nil
        jobs[index].statusErrorMessage = nil

        if jobs[index].inspection == nil {
            jobs[index].status = .scanning
            if autostartAfterInspection {
                pendingAutoStartAfterScan.insert(id)
            }
            scheduleScan(for: jobs[index])
        } else {
            jobs[index].status = .queued
            pendingAutoStartAfterScan.remove(id)
        }
    }

    private func scheduleNextIfPossible() {
        guard !isSchedulingNextJob else { return }
        isSchedulingNextJob = true
        startNextQueuedJobIfPossible()
    }

    private func startNextQueuedJobIfPossible() {
        for index in jobs.indices where jobs[index].status == .queued {
            guard let request = jobs[index].makeExecutionRequest(),
                  let inspection = jobs[index].inspection else {
                jobs[index].status = .scanning
                scheduleScan(for: jobs[index])
                continue
            }

            jobs[index].status = .preparing
            jobs[index].statusNote = nil
            jobs[index].statusErrorMessage = nil
            var runState = JobRunState.pending(from: inspection)
            runState.startedAt = .now
            runState.progress.startedAt = .now
            jobs[index].runState = runState
            persistJobs()

            let id = jobs[index].id
            Task { [queueEngine] in
                let didStart = await queueEngine.executeIfIdle(id: id, request: request)
                await MainActor.run {
                    self.finishSchedulingAttempt(for: id, didStart: didStart)
                }
            }
            return
        }

        isSchedulingNextJob = false
    }

    private func finishSchedulingAttempt(for jobID: UUID, didStart: Bool) {
        defer { isSchedulingNextJob = false }

        guard !didStart else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status == .preparing else { return }

        jobs[index].status = .queued
        jobs[index].runState = nil
        persistJobs()
    }

    private func finishScan(for jobID: UUID, inspection: JobInspectionSnapshot) {
        scanTasks[jobID] = nil
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        var inspection = inspection
        inspection.warnings = jobs[index].configuration.pruneSelections(to: inspection)
        jobs[index].inspection = inspection
        jobs[index].runState = nil
        jobs[index].statusNote = nil
        jobs[index].statusErrorMessage = nil
        jobs[index].status = .queued
        persistJobs()

        if pendingAutoStartAfterScan.remove(jobID) != nil {
            scheduleNextIfPossible()
        }
    }

    private func failScan(for jobID: UUID, error: Error) {
        scanTasks[jobID] = nil
        pendingAutoStartAfterScan.remove(jobID)
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard jobs[index].status != .cancelled else { return }
        jobs[index].status = .failed
        jobs[index].statusNote = nil
        jobs[index].statusErrorMessage = error.localizedDescription
        persistJobs()
    }

    private func apply(_ event: QueueEngineEvent) {
        switch event {
        case .prepared(let id, let outputFolder, let estimatedTotalUnits):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            jobs[index].runState?.outputFolderURL = outputFolder
            if let estimatedTotalUnits {
                jobs[index].runState?.progress.estimatedTotalFrames = max(
                    estimatedTotalUnits,
                    jobs[index].runState?.progress.completedFrames ?? 0
                )
            }
            if jobs[index].status != .paused {
                jobs[index].status = .running
                if jobs[index].runState?.startedAt == nil {
                    jobs[index].runState?.startedAt = .now
                }
                if jobs[index].runState?.progress.startedAt == nil {
                    jobs[index].runState?.progress.startedAt = .now
                }
            }

        case .note(let id, let note):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            jobs[index].runState?.note = note

        case .warning(let id, let message):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            appendUniqueWarning(message, to: &jobs[index].runState!.warnings)

        case .trackStatus(let id, let kind, let trackID, let status):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            updateTrackStatus(kind: kind, trackID: trackID, status: status, in: &jobs[index])
            if jobs[index].status != .paused, !status.isTerminal {
                jobs[index].status = .running
            }
            recomputeAggregateProgress(for: &jobs[index])

        case .trackProgress(let id, let kind, let trackID, let completedUnits, let estimatedTotalUnits):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            updateTrackProgress(
                kind: kind,
                trackID: trackID,
                completedUnits: completedUnits,
                estimatedTotalUnits: estimatedTotalUnits,
                in: &jobs[index]
            )
            if jobs[index].status != .paused {
                jobs[index].status = .running
            }
            recomputeAggregateProgress(for: &jobs[index])

        case .trackNote(let id, let kind, let trackID, let note):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            updateTrackNote(kind: kind, trackID: trackID, note: note, in: &jobs[index])

        case .trackWarning(let id, let kind, let trackID, let message):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            updateTrackWarning(kind: kind, trackID: trackID, warning: message, in: &jobs[index])

        case .finished(let id, let result):
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            ensureRunState(for: &jobs[index])
            switch result {
            case .success:
                jobs[index].runState?.finishedAt = .now
                recomputeAggregateProgress(for: &jobs[index])
                let hasFailedChild = jobs[index].runState?.videoTracks.contains(where: { $0.status == .failed }) == true
                    || jobs[index].runState?.audioTracks.contains(where: { $0.status == .failed }) == true
                if hasFailedChild {
                    jobs[index].status = .failed
                } else {
                    jobs[index].status = .completed
                    let finalCompleted = max(
                        jobs[index].runState?.progress.completedFrames ?? 0,
                        jobs[index].runState?.progress.estimatedTotalFrames ?? 0
                    )
                    jobs[index].runState?.progress.completedFrames = finalCompleted
                    jobs[index].runState?.progress.estimatedTotalFrames = finalCompleted
                }
            case .failure(let error):
                jobs[index].runState?.finishedAt = .now
                if case ConversionServiceError.cancelled = error {
                    jobs[index].status = .cancelled
                } else {
                    jobs[index].status = .failed
                    jobs[index].runState?.errorMessage = error.localizedDescription
                }
            }
            persistJobs()
            scheduleNextIfPossible()

        case .removed(let id):
            jobs.removeAll { $0.id == id }
            pendingAutoStartAfterScan.remove(id)
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
                let inspection = try await conversionService.inspectSource(for: sourceURL)
                self.finishScan(for: job.id, inspection: inspection)
            } catch is CancellationError {
            } catch {
                self.failScan(for: job.id, error: error)
            }
        }
        scanTasks[job.id] = scanTask
    }

    private func ensureRunState(for job: inout ConversionJob) {
        guard job.runState == nil, let inspection = job.inspection else { return }
        job.runState = JobRunState.pending(from: inspection)
    }

    private func updateTrackStatus(
        kind: TrackKind,
        trackID: Int32,
        status: ConversionStatus,
        in job: inout ConversionJob
    ) {
        switch kind {
        case .video:
            guard let index = job.runState?.videoTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.videoTracks[index].status = status
            if status == .running, job.runState?.videoTracks[index].progress.startedAt == nil {
                job.runState?.videoTracks[index].progress.startedAt = .now
            }
        case .audio:
            guard let index = job.runState?.audioTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.audioTracks[index].status = status
            if status == .running, job.runState?.audioTracks[index].progress.startedAt == nil {
                job.runState?.audioTracks[index].progress.startedAt = .now
            }
        case .timecode:
            break
        }
    }

    private func updateTrackProgress(
        kind: TrackKind,
        trackID: Int32,
        completedUnits: Int,
        estimatedTotalUnits: Int?,
        in job: inout ConversionJob
    ) {
        switch kind {
        case .video:
            guard let index = job.runState?.videoTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.videoTracks[index].progress.completedFrames = completedUnits
            if let estimatedTotalUnits {
                job.runState?.videoTracks[index].progress.estimatedTotalFrames = max(estimatedTotalUnits, completedUnits)
            }
        case .audio:
            guard let index = job.runState?.audioTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.audioTracks[index].progress.completedFrames = completedUnits
            if let estimatedTotalUnits {
                job.runState?.audioTracks[index].progress.estimatedTotalFrames = max(estimatedTotalUnits, completedUnits)
            }
        case .timecode:
            break
        }
    }

    private func updateTrackNote(
        kind: TrackKind,
        trackID: Int32,
        note: String,
        in job: inout ConversionJob
    ) {
        switch kind {
        case .video:
            guard let index = job.runState?.videoTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.videoTracks[index].note = note
        case .audio:
            guard let index = job.runState?.audioTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            job.runState?.audioTracks[index].note = note
        case .timecode:
            break
        }
    }

    private func updateTrackWarning(
        kind: TrackKind,
        trackID: Int32,
        warning: String,
        in job: inout ConversionJob
    ) {
        switch kind {
        case .video:
            guard let index = job.runState?.videoTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            appendUniqueWarning(warning, to: &job.runState!.videoTracks[index].warnings)
        case .audio:
            guard let index = job.runState?.audioTracks.firstIndex(where: { $0.mediaTrackID == trackID }) else { return }
            appendUniqueWarning(warning, to: &job.runState!.audioTracks[index].warnings)
        case .timecode:
            break
        }
    }

    private func recomputeAggregateProgress(for job: inout ConversionJob) {
        guard job.runState != nil else { return }
        let completedVideoFrames = job.runState?.videoTracks.reduce(0) { $0 + $1.progress.completedFrames } ?? 0
        let estimatedVideoFrames = job.runState?.videoTracks.reduce(0) { partial, track in
            partial + (track.progress.estimatedTotalFrames ?? 0)
        } ?? 0
        let completedAudioUnits = job.runState?.audioTracks.reduce(0) { $0 + min(1, $1.progress.completedFrames) } ?? 0
        let totalAudioUnits = job.runState?.audioTracks.count ?? 0

        job.runState?.progress.completedFrames = completedVideoFrames + completedAudioUnits
        let totalUnits = estimatedVideoFrames + totalAudioUnits
        job.runState?.progress.estimatedTotalFrames = totalUnits > 0 ? totalUnits : job.inspection?.totalProgressUnits
    }

    private func persistJobs() {
        let snapshot = jobs
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        Task { await AppStateStore.writer.saveJobs(snapshot, generation: generation) }
    }

    private static func restoredJob(_ persistedJob: ConversionJob) -> ConversionJob {
        var job = persistedJob

        switch job.status {
        case .completed, .failed, .cancelled:
            break
        case .queued:
            job.runState = nil
            job.status = job.inspection == nil ? .scanning : .queued
        case .scanning:
            job.runState = nil
            job.status = .scanning
        case .preparing, .running, .pausing, .paused, .cancelling:
            job.runState = nil
            job.status = job.inspection == nil ? .scanning : .queued
            job.statusNote = L10n.tr("app.job.restored_note")
            job.statusErrorMessage = nil
        }

        if job.status == .scanning {
            job.statusNote = nil
            job.statusErrorMessage = nil
        }

        return job
    }

    private static func needsRescan(_ job: ConversionJob) -> Bool {
        job.status == .scanning && job.inspection == nil
    }

    static func makeDefault() -> AppModel {
        AppModel(conversionService: ProResRAWConversionService())
    }
}

private func appendUniqueWarning(_ warning: String, to warnings: inout [String]) {
    guard !warnings.contains(warning) else { return }
    warnings.append(warning)
}
