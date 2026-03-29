//
//  QueueEngine.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

/// Events emitted by QueueEngine back to AppModel.
/// Each event describes a specific mutation — AppModel applies it to the single source of truth.
enum QueueEngineEvent: Sendable {
    case prepared(id: UUID, outputFolderURL: URL, estimatedFrames: Int?)
    case progress(id: UUID, completedFrames: Int, estimatedTotalFrames: Int?)
    case note(id: UUID, String)
    case warning(id: UUID, String)
    case clipSummary(id: UUID, ClipMetadataSummary)
    case finished(id: UUID, Result<Void, Error>)
    case removed(id: UUID)
}

private struct JobRuntime {
    let control: ConversionControl
    let task: Task<Void, Never>
}

/// Pure executor — owns no job data, only execution state.
/// AppModel is the single source of truth for all job state.
actor QueueEngine {
    nonisolated let events: AsyncStream<QueueEngineEvent>

    private let continuation: AsyncStream<QueueEngineEvent>.Continuation
    private let service: ProResRAWConversionService
    private var runtime: JobRuntime?
    private var activeJobID: UUID?
    private var pendingRemoval: Bool = false
    private var preemptedIDs: Set<UUID> = []

    init(service: ProResRAWConversionService) {
        self.service = service

        var continuation: AsyncStream<QueueEngineEvent>.Continuation!
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    var isIdle: Bool { activeJobID == nil }

    /// Start executing a conversion job. Only one job runs at a time.
    func execute(job: ConversionJob) {
        guard activeJobID == nil else { return }

        // If this job was cancelled before we could start, emit finished immediately
        if preemptedIDs.remove(job.id) != nil {
            emit(.finished(id: job.id, .failure(ConversionServiceError.cancelled)))
            return
        }

        let id = job.id
        let control = ConversionControl()
        activeJobID = id

        let request = ConversionRequest(
            sourceURL: job.sourceURL,
            outputDirectoryURL: job.outputDirectoryURL,
            compressionPreset: job.compressionPreset
        )

        let task = Task { [service] in
            do {
                try await service.convert(request: request, control: control) { [weak self] event in
                    await self?.handleConversionEvent(event, for: id)
                }
                self.finish(id: id, result: .success(()))
            } catch {
                self.finish(id: id, result: .failure(error))
            }
        }

        runtime = JobRuntime(control: control, task: task)
    }

    func pause() async {
        guard let runtime else { return }
        await runtime.control.pause()
    }

    func resume() async {
        guard let runtime else { return }
        await runtime.control.resume()
    }

    /// Cancel the active job, or preempt a job that was dispatched but not yet started.
    func cancel(id: UUID) async {
        if let activeJobID, activeJobID == id, let runtime {
            await runtime.control.cancel()
        } else {
            preemptedIDs.insert(id)
        }
    }

    /// Cancel the active job and request its removal from AppModel when finished.
    func cancelAndRemove(id: UUID) async {
        if let activeJobID, activeJobID == id {
            pendingRemoval = true
            await cancel(id: id)
        } else {
            emit(.removed(id: id))
        }
    }

    private func handleConversionEvent(_ event: ConversionEvent, for id: UUID) {
        switch event {
        case .clipSummary(let summary):
            emit(.clipSummary(id: id, summary))
        case .prepared(let outputFolder, let estimatedFrames):
            emit(.prepared(id: id, outputFolderURL: outputFolder, estimatedFrames: estimatedFrames))
        case .note(let note):
            emit(.note(id: id, note))
        case .warning(let message):
            emit(.warning(id: id, message))
        case .progress(let completedFrames, let estimatedTotalFrames):
            emit(.progress(id: id, completedFrames: completedFrames, estimatedTotalFrames: estimatedTotalFrames))
        }
    }

    private func finish(id: UUID, result: Result<Void, Error>) {
        runtime = nil
        if activeJobID == id {
            activeJobID = nil
        }

        if pendingRemoval {
            pendingRemoval = false
            emit(.removed(id: id))
        } else {
            emit(.finished(id: id, result))
        }
    }

    private func emit(_ event: QueueEngineEvent) {
        continuation.yield(event)
    }
}
