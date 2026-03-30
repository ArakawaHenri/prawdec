//
//  ProResRAWConversionService.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum ConversionServiceError: LocalizedError, Sendable {
    case noVideoTrack
    case cannotCreateAssetReader(String)
    case cannotCreateReaderOutput
    case cannotStartReading(String)
    case invalidPixelBuffer
    case missingRawMetadata(String)
    case unsupportedBayerPattern(Int)
    case cancelled
    case insufficientDiskSpace(requiredMB: Int, availableMB: Int)
    case outputDirectoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return L10n.tr("error.conversion.no_video_track")
        case .cannotCreateAssetReader(let message):
            return L10n.tr("error.conversion.cannot_create_asset_reader", message)
        case .cannotCreateReaderOutput:
            return L10n.tr("error.conversion.cannot_create_reader_output")
        case .cannotStartReading(let message):
            return L10n.tr("error.conversion.cannot_start_reading", message)
        case .invalidPixelBuffer:
            return L10n.tr("error.conversion.invalid_pixel_buffer")
        case .missingRawMetadata(let field):
            return L10n.tr("error.conversion.missing_raw_metadata", field)
        case .unsupportedBayerPattern(let rawValue):
            return L10n.tr("error.conversion.unsupported_bayer_pattern", rawValue)
        case .cancelled:
            return L10n.tr("error.conversion.cancelled")
        case .insufficientDiskSpace(let requiredMB, let availableMB):
            return L10n.tr("error.conversion.insufficient_disk_space", requiredMB, availableMB)
        case .outputDirectoryUnavailable(let path):
            return L10n.tr("error.conversion.output_directory_unavailable", path)
        }
    }
}

actor ConversionControl {
    private enum State {
        case running
        case paused
        case cancelled
    }

    private var state: State = .running
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func pause() {
        guard state == .running else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func cancel() {
        state = .cancelled
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func checkpoint() async throws {
        while true {
            switch state {
            case .running:
                return
            case .cancelled:
                throw ConversionServiceError.cancelled
            case .paused:
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }
        }
    }
}

struct ConversionRequest: Sendable {
    var sourceURL: URL
    var outputDirectoryURL: URL
    var outputFolderURL: URL?
    var compressionPreset: DNGCompressionPreset
    var videoTracks: [VideoTrackConversionRequest]
    var audioTracks: [AudioTrackConversionRequest]
}

enum ConversionEvent: Sendable {
    case prepared(outputFolder: URL, estimatedTotalUnits: Int?)
    case note(String)
    case warning(String)
    case trackStatus(kind: TrackKind, trackID: Int32, status: ConversionStatus)
    case trackProgress(kind: TrackKind, trackID: Int32, completedUnits: Int, estimatedTotalUnits: Int?)
    case trackNote(kind: TrackKind, trackID: Int32, String)
    case trackWarning(kind: TrackKind, trackID: Int32, String)
}

private struct ClipContext {
    var asset: AVURLAsset
    var track: AVAssetTrack
    var metadataDictionary: [String: Any]
    var clipColorMetadata: ClipColorMetadata
    var precomputedColorProfile: PrecomputedClipProfile?
    var summary: VideoTrackSummary
    var timecodeInfo: TimecodeInfo?
    var timecodeFormat: TimecodeFormat
}

private struct SourceAnalysis {
    var asset: AVURLAsset
    var metadataDictionary: [String: Any]
    var clipColorMetadata: ClipColorMetadata
    var precomputedColorProfile: PrecomputedClipProfile?
    var sourceMetadata: SourceMetadataSummary
    var videoTracksByID: [Int32: AVAssetTrack]
    var audioTracksByID: [Int32: AVAssetTrack]
    var timecodeSnapshotsByID: [Int32: TimecodeTrackSnapshot]
    var warnings: [String]
}

struct VideoTrackConversionRequest: Sendable {
    var trackID: Int32
    var outputStem: String
    var selectedTimecodeTrackID: Int32?
    var summary: VideoTrackSummary
}

struct AudioTrackConversionRequest: Sendable {
    var trackID: Int32
    var outputFileName: String
    var selectedTimecodeTrackID: Int32?
}

private struct RawFrameBuffer {
    var storedWidth: Int
    var storedHeight: Int
    var visibleWidth: Int
    var visibleHeight: Int
    var activeArea: [UInt32]
    var defaultCropOrigin: [Double]
    var defaultCropSize: [Double]
    var pixelData: Data
    var bytesPerRow: Int
}

private struct FrameMetadata {
    var redFactor: Double?
    var blueFactor: Double?
    var cct: Int?
    var blackLevel: UInt32
    var whiteLevel: UInt32
    var gainFactor: Double
    var bayerPattern: BayerPattern
    var colorMatrix: Matrix3x3?
    var make: String?
    var model: String?
    var uniqueCameraModel: String
}

/// Key for caching color science results between frames with identical inputs.
private struct ColorCacheKey: Equatable {
    var colorMatrix: Matrix3x3?
    var redFactor: Double?
    var blueFactor: Double?
    var cct: Int?
}

/// Frame-level color science cache, scoped to a single convert() call.
private struct ColorCache {
    var key: ColorCacheKey?
    var result: ResolvedFrameColorMetadata?
}

final class ProResRAWConversionService: Sendable {
    private let writer: any DNGWriting

    init(writer: any DNGWriting = AdobeDNGWriter()) {
        self.writer = writer
    }

    func inspectSource(for sourceURL: URL) async throws -> JobInspectionSnapshot {
        let analysis = try await analyzeSource(at: sourceURL)
        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let sortedTimecodeSnapshots = analysis.timecodeSnapshotsByID.values.sorted { $0.descriptor.index < $1.descriptor.index }
        let sortedVideoTracks = analysis.videoTracksByID.values.sorted(by: { $0.trackID < $1.trackID })
        let sortedAudioTracks = analysis.audioTracksByID.values.sorted(by: { $0.trackID < $1.trackID })
        let videoDescriptorsByID = await Self.makeTrackDescriptors(for: sortedVideoTracks, kind: .video)
        let audioDescriptorsByID = await Self.makeTrackDescriptors(for: sortedAudioTracks, kind: .audio)

        var videoTracks: [VideoTrackInspection] = []
        for track in sortedVideoTracks {
            guard let descriptor = videoDescriptorsByID[track.trackID] else { continue }
            let summary = try await summarizeVideoTrack(track)
            let options = try await makeTimecodeOptions(
                for: track,
                using: sortedTimecodeSnapshots
            )
            videoTracks.append(
                VideoTrackInspection(
                    track: descriptor,
                    summary: summary,
                    availableTimecodeOptions: options,
                    outputStem: "\(sourceStem)_\(descriptor.fileNameComponent)"
                )
            )
        }

        var audioTracks: [AudioTrackInspection] = []
        for track in sortedAudioTracks {
            guard let descriptor = audioDescriptorsByID[track.trackID] else { continue }
            let options = try await makeTimecodeOptions(
                for: track,
                using: sortedTimecodeSnapshots
            )
            audioTracks.append(
                AudioTrackInspection(
                    track: descriptor,
                    availableTimecodeOptions: options,
                    outputFileName: "\(sourceStem)_\(descriptor.fileNameComponent).wav"
                )
            )
        }

        return JobInspectionSnapshot(
            sourceMetadata: analysis.sourceMetadata,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            warnings: analysis.warnings
        )
    }

    func convert(
        request: ConversionRequest,
        control: ConversionControl,
        onEvent: @escaping @Sendable (ConversionEvent) async -> Void
    ) async throws {
        let outputFolder = try makeOutputFolder(
            sourceURL: request.sourceURL,
            outputDirectory: request.outputDirectoryURL,
            existingOutputFolder: request.outputFolderURL
        )

        try checkDiskSpace(
            outputDirectory: request.outputDirectoryURL,
            videoTracks: request.videoTracks,
            compressionPreset: request.compressionPreset
        )

        await onEvent(.prepared(outputFolder: outputFolder, estimatedTotalUnits: request.videoTracks.reduce(0) { $0 + ($1.summary.estimatedFrameCount ?? 0) } + request.audioTracks.count))

        let analysis = try await analyzeSource(at: request.sourceURL)
        for warning in analysis.warnings {
            await onEvent(.warning(warning))
        }

        for videoTrack in request.videoTracks {
            try Task.checkCancellation()
            try await control.checkpoint()

            let context = try await loadClipContext(
                from: analysis,
                videoTrack: videoTrack
            )

            await onEvent(.trackStatus(kind: .video, trackID: videoTrack.trackID, status: .running))
            if let tcInfo = context.timecodeInfo {
                await onEvent(.trackNote(kind: .video, trackID: videoTrack.trackID, L10n.tr("conversion.note.starting_timecode", tcInfo.startTimecode.description)))
            } else {
                await onEvent(.trackNote(kind: .video, trackID: videoTrack.trackID, L10n.tr("conversion.note.no_timecode_track")))
            }

            try await convertVideoTrack(
                request: videoTrack,
                compressionPreset: request.compressionPreset,
                outputFolder: outputFolder,
                clipContext: context,
                control: control,
                onEvent: onEvent
            )
        }

        for audioTrack in request.audioTracks {
            try Task.checkCancellation()
            try await control.checkpoint()
            guard let track = analysis.audioTracksByID[audioTrack.trackID] else { continue }

            await onEvent(.trackStatus(kind: .audio, trackID: audioTrack.trackID, status: .running))
            await onEvent(.trackProgress(kind: .audio, trackID: audioTrack.trackID, completedUnits: 0, estimatedTotalUnits: 1))

            let outputURL = outputFolder.appending(path: audioTrack.outputFileName)
            let startTimecode = try await startTimecode(
                for: track,
                selectedTimecodeTrackID: audioTrack.selectedTimecodeTrackID,
                snapshots: analysis.timecodeSnapshotsByID
            )

            do {
                try await AudioExtractor.extractAudio(
                    from: analysis.asset,
                    track: track,
                    to: outputURL,
                    bwfStartTimecode: startTimecode
                )
                await onEvent(.trackProgress(kind: .audio, trackID: audioTrack.trackID, completedUnits: 1, estimatedTotalUnits: 1))
                await onEvent(.trackStatus(kind: .audio, trackID: audioTrack.trackID, status: .completed))
                await onEvent(.trackNote(kind: .audio, trackID: audioTrack.trackID, L10n.tr("conversion.note.audio_exported", outputURL.lastPathComponent)))
            } catch {
                await onEvent(.trackStatus(kind: .audio, trackID: audioTrack.trackID, status: .failed))
                await onEvent(.trackWarning(kind: .audio, trackID: audioTrack.trackID, L10n.tr("conversion.warning.audio_export_failed", error.localizedDescription)))
            }
        }
    }

    private func analyzeSource(at url: URL) async throws -> SourceAnalysis {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ConversionServiceError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)

        let metadataDictionary = try await loadAssetMetadataDictionary(asset: asset)
        let clipColorMetadata = ColorScience.extractClipColorMetadata(from: metadataDictionary)

        let sortedTimecodeTracks = timecodeTracks.sorted(by: { $0.trackID < $1.trackID })
        let timecodeDescriptorsByID = await Self.makeTrackDescriptors(for: sortedTimecodeTracks, kind: .timecode)
        var timecodeSnapshotsByID: [Int32: TimecodeTrackSnapshot] = [:]
        var warnings: [String] = []
        for track in sortedTimecodeTracks {
            guard let descriptor = timecodeDescriptorsByID[track.trackID] else { continue }
            do {
                timecodeSnapshotsByID[track.trackID] = try await TimecodeExtractor.loadSnapshot(
                    from: asset,
                    track: track,
                    descriptor: descriptor
                )
            } catch {
                warnings.append(
                    L10n.tr(
                        "conversion.warning.timecode_track_skipped",
                        descriptor.displayName,
                        error.localizedDescription
                    )
                )
            }
        }

        let sourceMetadata = SourceMetadataSummary(
            manufacturer: metadataDictionary[ColorScience.quickTimeManufacturerKey] as? String,
            model: metadataDictionary[ColorScience.quickTimeModelKey] as? String,
            reportedCaptureCCT: clipColorMetadata.reportedCaptureCCT,
            whiteBalanceByCCTCount: clipColorMetadata.whiteBalanceByCCT.count,
            colorMatrixByCCTCount: clipColorMetadata.colorMatricesByCCT.count,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            timecodeTrackCount: timecodeTracks.count
        )
        let precomputedProfile = ColorScience.precomputeClipProfile(clipMetadata: clipColorMetadata)

        return SourceAnalysis(
            asset: asset,
            metadataDictionary: metadataDictionary,
            clipColorMetadata: clipColorMetadata,
            precomputedColorProfile: precomputedProfile,
            sourceMetadata: sourceMetadata,
            videoTracksByID: Dictionary(uniqueKeysWithValues: videoTracks.map { ($0.trackID, $0) }),
            audioTracksByID: Dictionary(uniqueKeysWithValues: audioTracks.map { ($0.trackID, $0) }),
            timecodeSnapshotsByID: timecodeSnapshotsByID,
            warnings: warnings
        )
    }

    private func summarizeVideoTrack(_ track: AVAssetTrack) async throws -> VideoTrackSummary {
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let timeRange = try await track.load(.timeRange)
        let durationSeconds = CMTimeGetSeconds(timeRange.duration)
        let estimatedFrameCount: Int?
        if nominalFrameRate > 0, durationSeconds.isFinite, durationSeconds > 0 {
            estimatedFrameCount = max(1, Int((nominalFrameRate * durationSeconds).rounded()))
        } else {
            estimatedFrameCount = nil
        }

        return VideoTrackSummary(
            dimensions: RasterDimensions(
                width: Int(naturalSize.width.rounded()),
                height: Int(naturalSize.height.rounded())
            ),
            nominalFrameRate: nominalFrameRate > 0 ? nominalFrameRate : nil,
            estimatedFrameCount: estimatedFrameCount
        )
    }

    private func loadClipContext(
        from analysis: SourceAnalysis,
        videoTrack: VideoTrackConversionRequest
    ) async throws -> ClipContext {
        guard let track = analysis.videoTracksByID[videoTrack.trackID] else {
            throw ConversionServiceError.noVideoTrack
        }

        let rawFrameRate = try await track.load(.nominalFrameRate)
        let fallbackFormat = try TimecodeExtractor.detectFormat(nominalFrameRate: rawFrameRate)
        let timecodeInfo = try await startTimecode(
            for: track,
            selectedTimecodeTrackID: videoTrack.selectedTimecodeTrackID,
            snapshots: analysis.timecodeSnapshotsByID
        )

        return ClipContext(
            asset: analysis.asset,
            track: track,
            metadataDictionary: analysis.metadataDictionary,
            clipColorMetadata: analysis.clipColorMetadata,
            precomputedColorProfile: analysis.precomputedColorProfile,
            summary: videoTrack.summary,
            timecodeInfo: timecodeInfo,
            timecodeFormat: timecodeInfo?.format ?? fallbackFormat
        )
    }

    private func startTimecode(
        for mediaTrack: AVAssetTrack,
        selectedTimecodeTrackID: Int32?,
        snapshots: [Int32: TimecodeTrackSnapshot]
    ) async throws -> TimecodeInfo? {
        guard let selectedTimecodeTrackID, let snapshot = snapshots[selectedTimecodeTrackID] else {
            return nil
        }
        guard let startTimecode = try await TimecodeExtractor.resolveStartTimecode(for: mediaTrack, using: snapshot) else {
            return nil
        }
        return TimecodeInfo(startTimecode: startTimecode, format: snapshot.format)
    }

    private func makeTimecodeOptions(
        for mediaTrack: AVAssetTrack,
        using snapshots: [TimecodeTrackSnapshot]
    ) async throws -> [TimecodeOption] {
        var options: [TimecodeOption] = []
        for snapshot in snapshots {
            if let startTimecode = try await TimecodeExtractor.resolveStartTimecode(for: mediaTrack, using: snapshot) {
                options.append(
                    TimecodeOption(
                        track: snapshot.descriptor,
                        startTimecode: startTimecode.description
                    )
                )
            }
        }
        return options
    }

    private static func makeTrackDescriptors(
        for tracks: [AVAssetTrack],
        kind: TrackKind,
    ) async -> [Int32: MediaTrackDescriptor] {
        var descriptors: [Int32: MediaTrackDescriptor] = [:]
        var usedFileNameComponents: Set<String> = []

        for (offset, track) in tracks.enumerated() {
            let index = offset + 1
            let metadataName = await loadTrackMetadataName(for: track)
            let displayName = metadataName ?? "\(kind.title) \(index)"
            let baseFileNameComponent: String
            if let metadataName {
                baseFileNameComponent = sanitizeTrackFileNameComponent(metadataName, fallbackIndex: index)
            } else {
                baseFileNameComponent = "track\(index)"
            }
            let fileNameComponent = uniqueTrackFileNameComponent(
                baseFileNameComponent,
                used: &usedFileNameComponents
            )
            descriptors[track.trackID] = MediaTrackDescriptor(
                trackID: track.trackID,
                kind: kind,
                index: index,
                displayName: displayName,
                fileNameComponent: fileNameComponent
            )
        }

        return descriptors
    }

    private static func loadTrackMetadataName(for track: AVAssetTrack) async -> String? {
        if let metadata = try? await track.load(.metadata) {
            for item in metadata {
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                let commonKey = item.commonKey?.rawValue.lowercased() ?? ""
                guard identifier.contains("name") || identifier.contains("title") || commonKey == "title" else {
                    continue
                }
                if let value = try? await item.load(.stringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func sanitizeTrackFileNameComponent(_ displayName: String, fallbackIndex: Int) -> String {
        let lowercased = displayName.lowercased()
        let normalized = lowercased.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "_",
            options: .regularExpression
        )
        let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "track\(fallbackIndex)" : trimmed
    }

    private static func uniqueTrackFileNameComponent(
        _ baseComponent: String,
        used: inout Set<String>
    ) -> String {
        var candidate = baseComponent
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(baseComponent)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private func convertVideoTrack(
        request: VideoTrackConversionRequest,
        compressionPreset: DNGCompressionPreset,
        outputFolder: URL,
        clipContext: ClipContext,
        control: ConversionControl,
        onEvent: @escaping @Sendable (ConversionEvent) async -> Void
    ) async throws {
        var colorCache = ColorCache()

        let reader = try AVAssetReader(asset: clipContext.asset)
        let outputSettings: [String: Any] = [
            AVVideoAllowWideColorKey: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_16VersatileBayer,
        ]
        let output = AVAssetReaderTrackOutput(track: clipContext.track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ConversionServiceError.cannotCreateReaderOutput
        }

        reader.add(output)
        guard reader.startReading() else {
            throw ConversionServiceError.cannotStartReading(reader.error?.localizedDescription ?? L10n.tr("error.common.unknown"))
        }

        var frameIndex = 0
        while reader.status == .reading {
            try Task.checkCancellation()
            try await control.checkpoint()
            try ensureDirectoryExists(at: outputFolder)

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            let writeRequest = try await makeWriteRequest(
                sampleBuffer: sampleBuffer,
                frameIndex: frameIndex,
                compressionPreset: compressionPreset,
                outputStem: request.outputStem,
                clipContext: clipContext,
                outputFolder: outputFolder,
                control: control,
                colorCache: &colorCache
            )

            if !writeRequest.payload.asShotNeutral.elementsEqual([1, 1, 1]) {
                await onEvent(.trackNote(kind: .video, trackID: request.trackID, L10n.tr("conversion.note.frame_resolved", frameIndex, writeRequest.payload.uniqueCameraModel)))
            }

            try writer.write(request: writeRequest)

            frameIndex += 1
            await onEvent(.trackProgress(kind: .video, trackID: request.trackID, completedUnits: frameIndex, estimatedTotalUnits: clipContext.summary.estimatedFrameCount))
        }

        if reader.status == .cancelled {
            throw ConversionServiceError.cancelled
        }
        if reader.status == .failed {
            throw ConversionServiceError.cannotStartReading(reader.error?.localizedDescription ?? L10n.tr("error.conversion.read_failed"))
        }

        await onEvent(.trackProgress(kind: .video, trackID: request.trackID, completedUnits: frameIndex, estimatedTotalUnits: frameIndex))
        await onEvent(.trackStatus(kind: .video, trackID: request.trackID, status: .completed))
    }

    private func loadAssetMetadataDictionary(asset: AVAsset) async throws -> [String: Any] {
        var dictionary: [String: Any] = [:]
        let formats = try await asset.load(.availableMetadataFormats)
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                guard let key = item.key as? String else { continue }
                if let data = try? await item.load(.dataValue) {
                    dictionary[key] = data
                } else if let string = try? await item.load(.stringValue) {
                    dictionary[key] = string
                } else if let number = try? await item.load(.numberValue) {
                    dictionary[key] = number
                } else if let value = try? await item.load(.value) {
                    dictionary[key] = value
                }
            }
        }
        return dictionary
    }

    private func makeOutputFolder(
        sourceURL: URL,
        outputDirectory: URL,
        existingOutputFolder: URL?
    ) throws -> URL {
        if let existingOutputFolder {
            try ensureDirectoryExists(at: existingOutputFolder)
            return existingOutputFolder
        }
        try ensureDirectoryExists(at: outputDirectory)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let base = outputDirectory.appending(path: stem, directoryHint: .isDirectory)
        var candidate = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appending(path: "\(stem) (\(suffix))", directoryHint: .isDirectory)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        throw ConversionServiceError.outputDirectoryUnavailable(url.path)
    }

    private func checkDiskSpace(
        outputDirectory: URL,
        videoTracks: [VideoTrackConversionRequest],
        compressionPreset: DNGCompressionPreset
    ) throws {
        let compressionFactor: Double = compressionPreset.isLossy ? 0.4 : 0.75
        let estimatedBytes = videoTracks.reduce(0) { partial, track in
            guard
                let dims = track.summary.dimensions,
                let frameCount = track.summary.estimatedFrameCount,
                frameCount > 0
            else {
                return partial
            }

            let rawBytesPerFrame = dims.width * dims.height * 2
            return partial + Int(Double(rawBytesPerFrame) * compressionFactor) * frameCount
        }
        guard estimatedBytes > 0 else { return }

        let resourceValues = try? outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let availableBytes = resourceValues?.volumeAvailableCapacityForImportantUsage else { return }

        let estimatedMB = estimatedBytes / (1024 * 1024)
        let availableMB = Int(availableBytes) / (1024 * 1024)

        if estimatedBytes > Int(availableBytes) {
            throw ConversionServiceError.insufficientDiskSpace(requiredMB: estimatedMB, availableMB: availableMB)
        }
    }

    private func makeWriteRequest(
        sampleBuffer: CMSampleBuffer,
        frameIndex: Int,
        compressionPreset: DNGCompressionPreset,
        outputStem: String,
        clipContext: ClipContext,
        outputFolder: URL,
        control: ConversionControl,
        colorCache: inout ColorCache
    ) async throws -> DNGWriteRequest {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ConversionServiceError.invalidPixelBuffer
        }

        let rawFrame = try await extractRawFrameBuffer(from: pixelBuffer, control: control)
        let metadata = try extractFrameMetadata(from: pixelBuffer, sampleBuffer: sampleBuffer, clipContext: clipContext)

        // Color science caching: skip recomputation when frame inputs haven't changed
        let cacheKey = ColorCacheKey(
            colorMatrix: metadata.colorMatrix,
            redFactor: metadata.redFactor,
            blueFactor: metadata.blueFactor,
            cct: metadata.cct
        )
        let resolved: ResolvedFrameColorMetadata
        if cacheKey == colorCache.key, let cached = colorCache.result {
            resolved = cached
        } else {
            resolved = try ColorScience.resolveFrameColorMetadata(
                frameAttachments: FrameColorAttachments(
                    colorMatrix: metadata.colorMatrix,
                    whiteBalanceRedFactor: metadata.redFactor,
                    whiteBalanceBlueFactor: metadata.blueFactor,
                    whiteBalanceCCT: metadata.cct
                ),
                clipMetadata: clipContext.clipColorMetadata,
                precomputedProfile: clipContext.precomputedColorProfile
            )
            colorCache.key = cacheKey
            colorCache.result = resolved
        }

        // Compute per-frame timecode
        let startTC = clipContext.timecodeInfo?.startTimecode
            ?? SMPTETimecode(hours: 0, minutes: 0, seconds: 0, frames: 0,
                             format: clipContext.timecodeFormat)
        let frameTC = TimecodeExtractor.timecodeForFrame(
            startTimecode: startTC,
            frameIndex: frameIndex
        )
        let tcData = frameTC.encodeSMPTE12MData()
        let frameRate = clipContext.timecodeFormat.rational

        let outputURL = outputFolder.appending(path: "\(outputStem)_\(String(format: "%08d", frameIndex + 1)).dng")

        let payload = DNGFramePayload(
            imageWidth: rawFrame.storedWidth,
            imageHeight: rawFrame.storedHeight,
            activeArea: rawFrame.activeArea,
            defaultCropOrigin: rawFrame.defaultCropOrigin,
            defaultCropSize: rawFrame.defaultCropSize,
            pixelData: rawFrame.pixelData,
            bytesPerRow: rawFrame.bytesPerRow,
            make: metadata.make,
            model: metadata.model,
            uniqueCameraModel: metadata.uniqueCameraModel,
            software: "prawdec",
            bayerPattern: metadata.bayerPattern,
            blackLevel: metadata.blackLevel,
            whiteLevel: metadata.whiteLevel,
            baselineExposure: log2(max(metadata.gainFactor, .ulpOfOne)),
            calibrationIlluminant1: resolved.calibrationIlluminant1,
            colorMatrix1: resolved.colorMatrix1,
            asShotNeutral: resolved.asShotNeutral,
            calibrationIlluminant2: resolved.calibrationIlluminant2,
            colorMatrix2: resolved.colorMatrix2,
            forwardMatrix1: resolved.forwardMatrix1,
            forwardMatrix2: resolved.forwardMatrix2,
            timecodeData: tcData,
            frameRate: frameRate
        )

        return DNGWriteRequest(
            destinationURL: outputURL,
            frameIndex: frameIndex,
            compression: compressionPreset,
            payload: payload
        )
    }

    private func extractFrameMetadata(
        from pixelBuffer: CVPixelBuffer,
        sampleBuffer _: CMSampleBuffer,
        clipContext: ClipContext
    ) throws -> FrameMetadata {
        let attachments = (CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any]) ?? [:]

        let blackLevel = attachments[kCVPixelBufferProResRAWKey_BlackLevel as String] as? NSNumber
        let whiteLevel = attachments[kCVPixelBufferProResRAWKey_WhiteLevel as String] as? NSNumber
        let gainFactor = attachments[kCVPixelBufferProResRAWKey_GainFactor as String] as? NSNumber
        let bayerPatternNumber = attachments[kCVPixelBufferVersatileBayerKey_BayerPattern as String] as? NSNumber

        guard let blackLevel, let whiteLevel, let gainFactor, let bayerPatternNumber else {
            throw ConversionServiceError.missingRawMetadata("black level / white level / gain factor / bayer pattern")
        }

        let colorMatrixData = attachments[kCVPixelBufferProResRAWKey_ColorMatrix as String] as? Data
        let colorMatrix: Matrix3x3?
        if let colorMatrixData, colorMatrixData.count == 9 * MemoryLayout<Float32>.size {
            colorMatrix = colorMatrixData.withUnsafeBytes { buffer -> Matrix3x3 in
                let floats = buffer.bindMemory(to: Float32.self)
                return Matrix3x3(rowMajor: [
                    Double(floats[0]), Double(floats[1]), Double(floats[2]),
                    Double(floats[3]), Double(floats[4]), Double(floats[5]),
                    Double(floats[6]), Double(floats[7]), Double(floats[8]),
                ])
            }
        } else {
            colorMatrix = nil
        }

        let make = clipContext.metadataDictionary[ColorScience.quickTimeManufacturerKey] as? String
        let model = clipContext.metadataDictionary[ColorScience.quickTimeModelKey] as? String
        let uniqueCameraModel = [make, model].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard let bayerPattern = BayerPattern.fromProResRAWValue(bayerPatternNumber.intValue) else {
            throw ConversionServiceError.unsupportedBayerPattern(bayerPatternNumber.intValue)
        }

        return FrameMetadata(
            redFactor: (attachments[kCVPixelBufferProResRAWKey_WhiteBalanceRedFactor as String] as? NSNumber)?.doubleValue,
            blueFactor: (attachments[kCVPixelBufferProResRAWKey_WhiteBalanceBlueFactor as String] as? NSNumber)?.doubleValue,
            cct: (attachments[kCVPixelBufferProResRAWKey_WhiteBalanceCCT as String] as? NSNumber)?.intValue,
            blackLevel: blackLevel.uint32Value,
            whiteLevel: whiteLevel.uint32Value,
            gainFactor: gainFactor.doubleValue,
            bayerPattern: bayerPattern,
            colorMatrix: colorMatrix,
            make: make,
            model: model,
            uniqueCameraModel: uniqueCameraModel.isEmpty ? "Unknown Camera" : uniqueCameraModel
        )
    }

    private func extractRawFrameBuffer(
        from pixelBuffer: CVPixelBuffer,
        control: ConversionControl
    ) async throws -> RawFrameBuffer {
        try await control.checkpoint()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ConversionServiceError.invalidPixelBuffer
        }

        let visibleWidth = CVPixelBufferGetWidth(pixelBuffer)
        let visibleHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dataSize = CVPixelBufferGetDataSize(pixelBuffer)

        var extraLeft: Int = 0
        var extraRight: Int = 0
        var extraTop: Int = 0
        var extraBottom: Int = 0
        CVPixelBufferGetExtendedPixels(
            pixelBuffer,
            &extraLeft,
            &extraRight,
            &extraTop,
            &extraBottom
        )

        let inferredWidth = max(Int(visibleWidth) + extraLeft + extraRight, Int(visibleWidth))
        let inferredHeight = max(Int(visibleHeight) + extraTop + extraBottom, Int(visibleHeight))
        let pixelBytesPerRow = min(bytesPerRow, inferredWidth * 2)
        let maxRowsFromData = bytesPerRow > 0 ? max(1, dataSize / bytesPerRow) : inferredHeight
        let storedHeight = min(inferredHeight, maxRowsFromData)
        let storedWidth = max(pixelBytesPerRow / 2, Int(visibleWidth))

        let bufferPointer = UnsafeRawPointer(baseAddress)
        // Single memcpy of the full buffer; stride handling deferred to DNG SDK via bytesPerRow
        let totalBytes = storedHeight * bytesPerRow
        let safeBytes = min(totalBytes, dataSize)
        let packedData = Data(bytes: bufferPointer, count: safeBytes)

        let crop = parseRecommendedCrop(from: CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any])
        let cropLeft = min(max(0, crop?.left ?? 0), Double(visibleWidth))
        let cropRight = min(max(0, crop?.right ?? 0), Double(visibleWidth))
        let cropTop = min(max(0, crop?.top ?? 0), Double(visibleHeight))
        let cropBottom = min(max(0, crop?.bottom ?? 0), Double(visibleHeight))
        let defaultCropOrigin = [
            max(0, Double(extraLeft)) + cropLeft,
            max(0, Double(extraTop)) + cropTop,
        ]
        let defaultCropSize = [
            max(1, Double(visibleWidth) - cropLeft - cropRight),
            max(1, Double(visibleHeight) - cropTop - cropBottom),
        ]

        return RawFrameBuffer(
            storedWidth: storedWidth,
            storedHeight: storedHeight,
            visibleWidth: Int(visibleWidth),
            visibleHeight: Int(visibleHeight),
            activeArea: [
                UInt32(max(0, extraTop)),
                UInt32(max(0, extraLeft)),
                UInt32(max(extraTop, extraTop + Int(visibleHeight))),
                UInt32(max(extraLeft, extraLeft + Int(visibleWidth))),
            ],
            defaultCropOrigin: defaultCropOrigin,
            defaultCropSize: defaultCropSize,
            pixelData: packedData,
            bytesPerRow: bytesPerRow
        )
    }

    private func parseRecommendedCrop(from attachments: [String: Any]?) -> (left: Double, right: Double, top: Double, bottom: Double)? {
        guard let data = attachments?[kCVPixelBufferProResRAWKey_RecommendedCrop as String] as? Data,
              data.count == 4 * MemoryLayout<Float32>.size
        else {
            return nil
        }

        let values = data.withUnsafeBytes { buffer -> (left: Double, right: Double, top: Double, bottom: Double)? in
            let floats = buffer.bindMemory(to: Float32.self)
            guard floats.count == 4 else { return nil }
            return (left: Double(floats[0]), right: Double(floats[1]),
                    top: Double(floats[2]), bottom: Double(floats[3]))
        }
        return values
    }
}
