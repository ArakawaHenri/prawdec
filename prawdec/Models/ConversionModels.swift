//
//  ConversionModels.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import Foundation

enum ConversionStatus: String, Codable, Sendable {
    case scanning
    case queued
    case preparing
    case running
    case pausing
    case paused
    case cancelling
    case cancelled
    case completed
    case failed

    var title: String {
        switch self {
        case .scanning:
            return L10n.tr("status.scanning")
        case .queued:
            return L10n.tr("status.queued")
        case .preparing:
            return L10n.tr("status.preparing")
        case .running:
            return L10n.tr("status.running")
        case .pausing:
            return L10n.tr("status.pausing")
        case .paused:
            return L10n.tr("status.paused")
        case .cancelling:
            return L10n.tr("status.cancelling")
        case .cancelled:
            return L10n.tr("status.cancelled")
        case .completed:
            return L10n.tr("status.completed")
        case .failed:
            return L10n.tr("status.failed")
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .running, .pausing, .cancelling:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .cancelled, .completed, .failed:
            return true
        default:
            return false
        }
    }
}

enum TrackKind: String, Codable, Sendable {
    case video
    case audio
    case timecode

    var title: String {
        switch self {
        case .video:
            return L10n.tr("track.kind.video")
        case .audio:
            return L10n.tr("track.kind.audio")
        case .timecode:
            return L10n.tr("track.kind.timecode")
        }
    }
}

enum MetadataQuality: String, Codable, Sendable {
    case dualTables
    case wbTableOnly
    case singleFrameOnly
    case unknown

    var title: String {
        switch self {
        case .dualTables:
            return L10n.tr("metadata.quality.dual_tables")
        case .wbTableOnly:
            return L10n.tr("metadata.quality.wb_table_only")
        case .singleFrameOnly:
            return L10n.tr("metadata.quality.single_frame_only")
        case .unknown:
            return L10n.tr("metadata.quality.unknown")
        }
    }
}

struct RasterDimensions: Codable, Hashable, Sendable {
    var width: Int
    var height: Int

    var description: String {
        "\(width)×\(height)"
    }
}

struct JobProgress: Codable, Hashable, Sendable {
    var completedFrames: Int = 0
    var estimatedTotalFrames: Int?
    var startedAt: Date?

    var fractionCompleted: Double {
        guard let estimatedTotalFrames, estimatedTotalFrames > 0 else {
            return 0
        }
        return min(1, Double(completedFrames) / Double(estimatedTotalFrames))
    }

    var frameLabel: String {
        if let estimatedTotalFrames {
            return "\(completedFrames) / \(estimatedTotalFrames)"
        }
        return "\(completedFrames)"
    }

    var fps: Double? {
        guard let startedAt, completedFrames > 0 else { return nil }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return nil }
        return Double(completedFrames) / elapsed
    }

    var estimatedTimeRemaining: TimeInterval? {
        guard let fps, fps > 0, let estimatedTotalFrames, estimatedTotalFrames > completedFrames else { return nil }
        return Double(estimatedTotalFrames - completedFrames) / fps
    }

    var etaLabel: String? {
        guard let eta = estimatedTimeRemaining else { return nil }
        if eta < 60 {
            return L10n.tr("progress.eta.seconds", Int(eta))
        } else if eta < 3600 {
            let minutes = Int(eta) / 60
            let seconds = Int(eta) % 60
            return L10n.tr("progress.eta.minutes", minutes, seconds)
        } else {
            let hours = Int(eta) / 3600
            let minutes = (Int(eta) % 3600) / 60
            return L10n.tr("progress.eta.hours", hours, minutes, Int(eta) % 60)
        }
    }

    var speedLabel: String? {
        guard let fps else { return nil }
        return L10n.tr("progress.fps", fps)
    }
}

struct MediaTrackDescriptor: Codable, Hashable, Identifiable, Sendable {
    var trackID: Int32
    var kind: TrackKind
    var index: Int
    var displayName: String
    var fileNameComponent: String

    var id: String {
        "\(kind.rawValue)-\(trackID)"
    }
}

struct TimecodeOption: Codable, Hashable, Identifiable, Sendable {
    var track: MediaTrackDescriptor
    var startTimecode: String

    var id: Int32 { track.trackID }

    var title: String {
        "\(track.displayName) - \(startTimecode)"
    }
}

struct SourceMetadataSummary: Codable, Hashable, Sendable {
    var manufacturer: String?
    var model: String?
    var reportedCaptureCCT: Int?
    var whiteBalanceByCCTCount: Int = 0
    var colorMatrixByCCTCount: Int = 0
    var videoTrackCount: Int = 0
    var audioTrackCount: Int = 0
    var timecodeTrackCount: Int = 0

    var quality: MetadataQuality {
        if whiteBalanceByCCTCount > 0 && colorMatrixByCCTCount > 0 {
            return .dualTables
        }
        if whiteBalanceByCCTCount > 0 {
            return .wbTableOnly
        }
        if manufacturer != nil || model != nil || reportedCaptureCCT != nil {
            return .singleFrameOnly
        }
        return .unknown
    }
}

struct VideoTrackSummary: Codable, Hashable, Sendable {
    var dimensions: RasterDimensions?
    var nominalFrameRate: Double?
    var estimatedFrameCount: Int?
}

struct TrackTimecodeSelection: Codable, Hashable, Identifiable, Sendable {
    var mediaTrackID: Int32
    var selectedTimecodeTrackID: Int32?

    var id: Int32 { mediaTrackID }
}

struct JobConfiguration: Codable, Hashable, Sendable {
    var outputDirectoryURL: URL
    var compressionPreset: DNGCompressionPreset
    var videoTimecodeSelections: [TrackTimecodeSelection] = []
    var audioTimecodeSelections: [TrackTimecodeSelection] = []

    func selectedTimecodeTrackID(for mediaTrackID: Int32, kind: TrackKind) -> Int32? {
        switch kind {
        case .video:
            return videoTimecodeSelections.first(where: { $0.mediaTrackID == mediaTrackID })?.selectedTimecodeTrackID
        case .audio:
            return audioTimecodeSelections.first(where: { $0.mediaTrackID == mediaTrackID })?.selectedTimecodeTrackID
        case .timecode:
            return nil
        }
    }

    mutating func setSelectedTimecodeTrackID(_ selectedTimecodeTrackID: Int32?, for mediaTrackID: Int32, kind: TrackKind) {
        switch kind {
        case .video:
            var selections = videoTimecodeSelections
            Self.updateSelectionArray(&selections, mediaTrackID: mediaTrackID, selectedTimecodeTrackID: selectedTimecodeTrackID)
            videoTimecodeSelections = selections
        case .audio:
            var selections = audioTimecodeSelections
            Self.updateSelectionArray(&selections, mediaTrackID: mediaTrackID, selectedTimecodeTrackID: selectedTimecodeTrackID)
            audioTimecodeSelections = selections
        case .timecode:
            break
        }
    }

    mutating func pruneSelections(to inspection: JobInspectionSnapshot) -> [String] {
        var warnings: [String] = inspection.warnings
        var videoSelections = videoTimecodeSelections
        Self.pruneSelections(
            &videoSelections,
            tracks: inspection.videoTracks,
            warningTarget: &warnings
        )
        videoTimecodeSelections = videoSelections
        var audioSelections = audioTimecodeSelections
        Self.pruneSelections(
            &audioSelections,
            tracks: inspection.audioTracks,
            warningTarget: &warnings
        )
        audioTimecodeSelections = audioSelections
        return warnings
    }

    private static func updateSelectionArray(
        _ selections: inout [TrackTimecodeSelection],
        mediaTrackID: Int32,
        selectedTimecodeTrackID: Int32?
    ) {
        if let index = selections.firstIndex(where: { $0.mediaTrackID == mediaTrackID }) {
            selections[index].selectedTimecodeTrackID = selectedTimecodeTrackID
        } else {
            selections.append(
                TrackTimecodeSelection(
                    mediaTrackID: mediaTrackID,
                    selectedTimecodeTrackID: selectedTimecodeTrackID
                )
            )
        }
    }

    private static func pruneSelections<Track>(
        _ selections: inout [TrackTimecodeSelection],
        tracks: [Track],
        warningTarget: inout [String]
    ) where Track: InspectionTrack {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.track.trackID, $0) })
        selections.removeAll { tracksByID[$0.mediaTrackID] == nil }
        for index in selections.indices {
            guard let track = tracksByID[selections[index].mediaTrackID] else { continue }
            guard let selectedTimecodeTrackID = selections[index].selectedTimecodeTrackID else { continue }
            guard !track.availableTimecodeOptions.contains(where: { $0.track.trackID == selectedTimecodeTrackID }) else {
                continue
            }
            appendUniqueWarning(
                L10n.tr("conversion.warning.timecode_selection_reset", track.track.displayName),
                to: &warningTarget
            )
            selections[index].selectedTimecodeTrackID = nil
        }
    }
}

protocol InspectionTrack: Sendable {
    var track: MediaTrackDescriptor { get }
    var availableTimecodeOptions: [TimecodeOption] { get }
}

struct VideoTrackInspection: Codable, Hashable, Identifiable, Sendable, InspectionTrack {
    var track: MediaTrackDescriptor
    var summary: VideoTrackSummary
    var availableTimecodeOptions: [TimecodeOption]
    var outputStem: String

    var id: String { track.id }
}

struct AudioTrackInspection: Codable, Hashable, Identifiable, Sendable, InspectionTrack {
    var track: MediaTrackDescriptor
    var availableTimecodeOptions: [TimecodeOption]
    var outputFileName: String

    var id: String { track.id }
}

struct JobInspectionSnapshot: Codable, Hashable, Sendable {
    var sourceMetadata: SourceMetadataSummary
    var videoTracks: [VideoTrackInspection]
    var audioTracks: [AudioTrackInspection]
    var warnings: [String] = []
    var scannedAt: Date = .now

    var totalProgressUnits: Int {
        videoTracks.reduce(0) { $0 + max(0, $1.summary.estimatedFrameCount ?? 0) } + audioTracks.count
    }
}

struct TrackRunState: Codable, Hashable, Identifiable, Sendable {
    var mediaTrackID: Int32
    var status: ConversionStatus = .queued
    var progress: JobProgress = JobProgress()
    var note: String?
    var warnings: [String] = []
    var errorMessage: String?

    var id: Int32 { mediaTrackID }
}

struct JobRunState: Codable, Hashable, Sendable {
    var outputFolderURL: URL?
    var progress: JobProgress
    var note: String?
    var warnings: [String]
    var errorMessage: String?
    var startedAt: Date?
    var finishedAt: Date?
    var videoTracks: [TrackRunState]
    var audioTracks: [TrackRunState]

    static func pending(from inspection: JobInspectionSnapshot) -> JobRunState {
        JobRunState(
            outputFolderURL: nil,
            progress: JobProgress(
                completedFrames: 0,
                estimatedTotalFrames: inspection.totalProgressUnits,
                startedAt: nil
            ),
            note: nil,
            warnings: [],
            errorMessage: nil,
            startedAt: nil,
            finishedAt: nil,
            videoTracks: inspection.videoTracks.map {
                TrackRunState(
                    mediaTrackID: $0.track.trackID,
                    status: .queued,
                    progress: JobProgress(
                        completedFrames: 0,
                        estimatedTotalFrames: $0.summary.estimatedFrameCount,
                        startedAt: nil
                    ),
                    note: nil,
                    warnings: [],
                    errorMessage: nil
                )
            },
            audioTracks: inspection.audioTracks.map {
                TrackRunState(
                    mediaTrackID: $0.track.trackID,
                    status: .queued,
                    progress: JobProgress(
                        completedFrames: 0,
                        estimatedTotalFrames: 1,
                        startedAt: nil
                    ),
                    note: nil,
                    warnings: [],
                    errorMessage: nil
                )
            }
        )
    }
}

struct VideoTrackJob: Hashable, Identifiable, Sendable {
    var track: MediaTrackDescriptor
    var summary: VideoTrackSummary
    var selectedTimecodeTrackID: Int32?
    var availableTimecodeOptions: [TimecodeOption]
    var status: ConversionStatus
    var progress: JobProgress
    var note: String?
    var warnings: [String]
    var errorMessage: String?
    var outputStem: String

    var id: String { track.id }

    var selectedTimecodeOption: TimecodeOption? {
        guard let selectedTimecodeTrackID else { return availableTimecodeOptions.first }
        return availableTimecodeOptions.first { $0.track.trackID == selectedTimecodeTrackID }
            ?? availableTimecodeOptions.first
    }

    var effectiveSelectedTimecodeTrackID: Int32? {
        selectedTimecodeOption?.track.trackID
    }

    var canChooseTimecode: Bool {
        availableTimecodeOptions.count > 1
    }
}

struct AudioTrackJob: Hashable, Identifiable, Sendable {
    var track: MediaTrackDescriptor
    var selectedTimecodeTrackID: Int32?
    var availableTimecodeOptions: [TimecodeOption]
    var status: ConversionStatus
    var progress: JobProgress
    var note: String?
    var warnings: [String]
    var errorMessage: String?
    var outputFileName: String

    var id: String { track.id }

    var selectedTimecodeOption: TimecodeOption? {
        guard let selectedTimecodeTrackID else { return availableTimecodeOptions.first }
        return availableTimecodeOptions.first { $0.track.trackID == selectedTimecodeTrackID }
            ?? availableTimecodeOptions.first
    }

    var effectiveSelectedTimecodeTrackID: Int32? {
        selectedTimecodeOption?.track.trackID
    }

    var canChooseTimecode: Bool {
        availableTimecodeOptions.count > 1
    }
}

struct ConversionJob: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceURL: URL
    var configuration: JobConfiguration
    var status: ConversionStatus
    var inspection: JobInspectionSnapshot?
    var runState: JobRunState?
    var statusNote: String?
    var statusErrorMessage: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        configuration: JobConfiguration,
        status: ConversionStatus = .scanning,
        inspection: JobInspectionSnapshot? = nil,
        runState: JobRunState? = nil,
        statusNote: String? = nil,
        statusErrorMessage: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.configuration = configuration
        self.status = status
        self.inspection = inspection
        self.runState = runState
        self.statusNote = statusNote
        self.statusErrorMessage = statusErrorMessage
        self.createdAt = createdAt
    }

    var displayName: String {
        let component = sourceURL.lastPathComponent
        return component.isEmpty ? sourceURL.path : component
    }

    var outputDirectoryURL: URL { configuration.outputDirectoryURL }
    var compressionPreset: DNGCompressionPreset { configuration.compressionPreset }
    var outputFolderURL: URL? { runState?.outputFolderURL }
    var sourceMetadata: SourceMetadataSummary? { inspection?.sourceMetadata }
    var progress: JobProgress { runState?.progress ?? pendingProgress }
    var note: String? { runState?.note ?? statusNote }
    var errorMessage: String? { runState?.errorMessage ?? statusErrorMessage }
    var startedAt: Date? { runState?.startedAt }
    var finishedAt: Date? { runState?.finishedAt }

    var warnings: [String] {
        var merged: [String] = inspection?.warnings ?? []
        for warning in runState?.warnings ?? [] {
            appendUniqueWarning(warning, to: &merged)
        }
        return merged
    }

    var videoTracks: [VideoTrackJob] {
        guard let inspection else { return [] }
        return inspection.videoTracks.map { track in
            let configuredTimecodeTrackID = configuration.selectedTimecodeTrackID(
                for: track.track.trackID,
                kind: .video
            )
            let selectedTimecodeTrackID = configuredTimecodeTrackID
                ?? track.availableTimecodeOptions.first?.track.trackID
            let runtime = runState?.videoTracks.first(where: { $0.mediaTrackID == track.track.trackID })
            return VideoTrackJob(
                track: track.track,
                summary: track.summary,
                selectedTimecodeTrackID: selectedTimecodeTrackID,
                availableTimecodeOptions: track.availableTimecodeOptions,
                status: runtime?.status ?? .queued,
                progress: runtime?.progress ?? JobProgress(
                    completedFrames: 0,
                    estimatedTotalFrames: track.summary.estimatedFrameCount,
                    startedAt: nil
                ),
                note: runtime?.note,
                warnings: runtime?.warnings ?? [],
                errorMessage: runtime?.errorMessage,
                outputStem: track.outputStem
            )
        }
    }

    var audioTracks: [AudioTrackJob] {
        guard let inspection else { return [] }
        return inspection.audioTracks.map { track in
            let configuredTimecodeTrackID = configuration.selectedTimecodeTrackID(
                for: track.track.trackID,
                kind: .audio
            )
            let selectedTimecodeTrackID = configuredTimecodeTrackID
                ?? track.availableTimecodeOptions.first?.track.trackID
            let runtime = runState?.audioTracks.first(where: { $0.mediaTrackID == track.track.trackID })
            return AudioTrackJob(
                track: track.track,
                selectedTimecodeTrackID: selectedTimecodeTrackID,
                availableTimecodeOptions: track.availableTimecodeOptions,
                status: runtime?.status ?? .queued,
                progress: runtime?.progress ?? JobProgress(
                    completedFrames: 0,
                    estimatedTotalFrames: 1,
                    startedAt: nil
                ),
                note: runtime?.note,
                warnings: runtime?.warnings ?? [],
                errorMessage: runtime?.errorMessage,
                outputFileName: track.outputFileName
            )
        }
    }

    var videoFrameCount: Int {
        inspection?.videoTracks.reduce(0) { $0 + max(0, $1.summary.estimatedFrameCount ?? 0) } ?? 0
    }

    var totalProgressUnits: Int {
        inspection?.totalProgressUnits ?? 0
    }

    var canStart: Bool {
        switch status {
        case .queued, .paused, .failed, .cancelled:
            return true
        case .completed, .running, .preparing, .pausing, .cancelling, .scanning:
            return false
        }
    }

    var canPause: Bool {
        status == .running || status == .preparing
    }

    var canResume: Bool {
        status == .paused
    }

    var canCancel: Bool {
        switch status {
        case .scanning, .queued, .preparing, .running, .pausing, .paused, .cancelling:
            return true
        case .cancelled, .completed, .failed:
            return false
        }
    }

    var canRemove: Bool {
        true
    }

    var canEditConfiguration: Bool {
        switch status {
        case .scanning, .queued, .failed, .cancelled:
            return true
        case .preparing, .running, .pausing, .paused, .cancelling, .completed:
            return false
        }
    }

    var isReadyForExecution: Bool {
        inspection != nil
    }

    func makeExecutionRequest() -> ConversionRequest? {
        guard let inspection else { return nil }
        return ConversionRequest(
            sourceURL: sourceURL,
            outputDirectoryURL: configuration.outputDirectoryURL,
            outputFolderURL: runState?.outputFolderURL,
            compressionPreset: configuration.compressionPreset,
            videoTracks: inspection.videoTracks.map {
                VideoTrackConversionRequest(
                    trackID: $0.track.trackID,
                    outputStem: $0.outputStem,
                    selectedTimecodeTrackID: resolvedTimecodeTrackID(
                        for: $0.track.trackID,
                        kind: .video,
                        availableOptions: $0.availableTimecodeOptions
                    ),
                    summary: $0.summary
                )
            },
            audioTracks: inspection.audioTracks.map {
                AudioTrackConversionRequest(
                    trackID: $0.track.trackID,
                    outputFileName: $0.outputFileName,
                    selectedTimecodeTrackID: resolvedTimecodeTrackID(
                        for: $0.track.trackID,
                        kind: .audio,
                        availableOptions: $0.availableTimecodeOptions
                    )
                )
            }
        )
    }

    private var pendingProgress: JobProgress {
        JobProgress(
            completedFrames: 0,
            estimatedTotalFrames: inspection?.totalProgressUnits,
            startedAt: nil
        )
    }

    private func resolvedTimecodeTrackID(
        for mediaTrackID: Int32,
        kind: TrackKind,
        availableOptions: [TimecodeOption]
    ) -> Int32? {
        guard let selectedTimecodeTrackID = configuration.selectedTimecodeTrackID(for: mediaTrackID, kind: kind) else {
            return availableOptions.first?.track.trackID
        }
        return availableOptions.first(where: { $0.track.trackID == selectedTimecodeTrackID })?.track.trackID
            ?? availableOptions.first?.track.trackID
    }
}

private func appendUniqueWarning(_ warning: String, to warnings: inout [String]) {
    guard !warnings.contains(warning) else { return }
    warnings.append(warning)
}
