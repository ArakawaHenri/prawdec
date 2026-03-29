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

    /// Frames per second processing speed
    var fps: Double? {
        guard let startedAt, completedFrames > 0 else { return nil }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return nil }
        return Double(completedFrames) / elapsed
    }

    /// Estimated seconds remaining
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

struct ClipMetadataSummary: Codable, Hashable, Sendable {
    var dimensions: RasterDimensions?
    var nominalFrameRate: Double?
    var estimatedFrameCount: Int?
    var manufacturer: String?
    var model: String?
    var reportedCaptureCCT: Int?
    var whiteBalanceByCCTCount: Int = 0
    var colorMatrixByCCTCount: Int = 0

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

struct ConversionJob: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sourceURL: URL
    var outputDirectoryURL: URL
    var compressionPreset: DNGCompressionPreset
    var status: ConversionStatus
    var progress: JobProgress
    var clipMetadata: ClipMetadataSummary?
    var note: String?
    var warnings: [String]
    var errorMessage: String?
    var outputFolderURL: URL?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        outputDirectoryURL: URL,
        compressionPreset: DNGCompressionPreset = .jpegLossless,
        status: ConversionStatus = .scanning,
        progress: JobProgress = JobProgress(),
        clipMetadata: ClipMetadataSummary? = nil,
        note: String? = nil,
        warnings: [String] = [],
        errorMessage: String? = nil,
        outputFolderURL: URL? = nil,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.outputDirectoryURL = outputDirectoryURL
        self.compressionPreset = compressionPreset
        self.status = status
        self.progress = progress
        self.clipMetadata = clipMetadata
        self.note = note
        self.warnings = warnings
        self.errorMessage = errorMessage
        self.outputFolderURL = outputFolderURL
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var displayName: String {
        let component = sourceURL.lastPathComponent
        return component.isEmpty ? sourceURL.path : component
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
}
