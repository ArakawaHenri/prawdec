//
//  QueueEngine.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum QueueEngineEvent: Sendable {
    case prepared(id: UUID, outputFolderURL: URL, estimatedTotalUnits: Int?)
    case note(id: UUID, String)
    case warning(id: UUID, String)
    case trackStatus(id: UUID, kind: TrackKind, trackID: Int32, status: ConversionStatus)
    case trackProgress(id: UUID, kind: TrackKind, trackID: Int32, completedUnits: Int, estimatedTotalUnits: Int?)
    case trackNote(id: UUID, kind: TrackKind, trackID: Int32, String)
    case trackWarning(id: UUID, kind: TrackKind, trackID: Int32, String)
    case finished(id: UUID, Result<Void, Error>)
    case removed(id: UUID)
}

private struct JobRuntime {
    let control: ConversionControl
    let task: Task<Void, Never>
}

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

    @discardableResult
    func executeIfIdle(id: UUID, request: ConversionRequest) -> Bool {
        guard activeJobID == nil else { return false }

        if preemptedIDs.remove(id) != nil {
            emit(.finished(id: id, .failure(ConversionServiceError.cancelled)))
            return true
        }

        let control = ConversionControl()
        activeJobID = id

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
        return true
    }

    func pause() async {
        guard let runtime else { return }
        await runtime.control.pause()
    }

    func resume() async {
        guard let runtime else { return }
        await runtime.control.resume()
    }

    func cancel(id: UUID) async {
        if let activeJobID, activeJobID == id, let runtime {
            await runtime.control.cancel()
        } else {
            preemptedIDs.insert(id)
        }
    }

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
        case .prepared(let outputFolder, let estimatedTotalUnits):
            emit(.prepared(id: id, outputFolderURL: outputFolder, estimatedTotalUnits: estimatedTotalUnits))
        case .note(let note):
            emit(.note(id: id, note))
        case .warning(let message):
            emit(.warning(id: id, message))
        case .trackStatus(let kind, let trackID, let status):
            emit(.trackStatus(id: id, kind: kind, trackID: trackID, status: status))
        case .trackProgress(let kind, let trackID, let completedUnits, let estimatedTotalUnits):
            emit(.trackProgress(id: id, kind: kind, trackID: trackID, completedUnits: completedUnits, estimatedTotalUnits: estimatedTotalUnits))
        case .trackNote(let kind, let trackID, let message):
            emit(.trackNote(id: id, kind: kind, trackID: trackID, message))
        case .trackWarning(let kind, let trackID, let message):
            emit(.trackWarning(id: id, kind: kind, trackID: trackID, message))
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
