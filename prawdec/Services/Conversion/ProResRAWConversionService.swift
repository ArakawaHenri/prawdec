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
    var compressionPreset: DNGCompressionPreset
}

enum ConversionEvent: Sendable {
    case clipSummary(ClipMetadataSummary)
    case prepared(outputFolder: URL, estimatedFrames: Int?)
    case note(String)
    case warning(String)
    case progress(completedFrames: Int, estimatedTotalFrames: Int?)
}

private struct ClipContext {
    var asset: AVURLAsset
    var track: AVAssetTrack
    var metadataDictionary: [String: Any]
    var clipColorMetadata: ClipColorMetadata
    var precomputedColorProfile: PrecomputedClipProfile?
    var summary: ClipMetadataSummary
    var timecodeInfo: TimecodeInfo?
    var timecodeFormat: TimecodeFormat
    var hasAudio: Bool
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

    func scanClipSummary(for sourceURL: URL) async throws -> ClipMetadataSummary {
        try await loadClipContext(for: sourceURL).summary
    }

    func convert(
        request: ConversionRequest,
        control: ConversionControl,
        onEvent: @escaping @Sendable (ConversionEvent) async -> Void
    ) async throws {
        var colorCache = ColorCache()

        let context = try await loadClipContext(for: request.sourceURL)
        await onEvent(.clipSummary(context.summary))

        // Log timecode info
        if let tcInfo = context.timecodeInfo {
            await onEvent(.note(L10n.tr("conversion.note.starting_timecode", tcInfo.startTimecode.description)))
        } else {
            await onEvent(.note(L10n.tr("conversion.note.no_timecode_track")))
        }

        let outputFolder = try makeOutputFolder(
            sourceURL: request.sourceURL,
            outputDirectory: request.outputDirectoryURL,
            compressionPreset: request.compressionPreset
        )

        // Disk space check
        try checkDiskSpace(
            outputDirectory: request.outputDirectoryURL,
            dimensions: context.summary.dimensions,
            estimatedFrameCount: context.summary.estimatedFrameCount,
            compressionPreset: request.compressionPreset
        )

        await onEvent(.prepared(outputFolder: outputFolder, estimatedFrames: context.summary.estimatedFrameCount))

        let reader = try AVAssetReader(asset: context.asset)
        let outputSettings: [String: Any] = [
            AVVideoAllowWideColorKey: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_16VersatileBayer,
        ]
        let output = AVAssetReaderTrackOutput(track: context.track, outputSettings: outputSettings)
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
                request: request,
                clipContext: context,
                outputFolder: outputFolder,
                control: control,
                colorCache: &colorCache
            )

            if !writeRequest.payload.asShotNeutral.elementsEqual([1, 1, 1]) {
                await onEvent(.note(L10n.tr("conversion.note.frame_resolved", frameIndex, writeRequest.payload.uniqueCameraModel)))
            }

            try writer.write(request: writeRequest)

            frameIndex += 1
            await onEvent(.progress(completedFrames: frameIndex, estimatedTotalFrames: context.summary.estimatedFrameCount))
        }

        if reader.status == .cancelled {
            throw ConversionServiceError.cancelled
        }
        if reader.status == .failed {
            throw ConversionServiceError.cannotStartReading(reader.error?.localizedDescription ?? L10n.tr("error.conversion.read_failed"))
        }

        // Extract audio to WAV sidecar
        if context.hasAudio {
            try ensureDirectoryExists(at: outputFolder)
            let folderName = outputFolder.lastPathComponent
            let audioURL = outputFolder.appending(path: "\(folderName).wav")
            do {
                try await AudioExtractor.extractAudio(from: context.asset, to: audioURL)
                await onEvent(.note(L10n.tr("conversion.note.audio_exported", audioURL.lastPathComponent)))
            } catch {
                await onEvent(.warning(L10n.tr("conversion.warning.audio_export_failed", error.localizedDescription)))
            }
        }
    }

    private func loadClipContext(for url: URL) async throws -> ClipContext {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionServiceError.noVideoTrack
        }

        let metadataDictionary = try await loadAssetMetadataDictionary(asset: asset)
        let clipColorMetadata = ColorScience.extractClipColorMetadata(from: metadataDictionary)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        let dimensions = RasterDimensions(
            width: Int(naturalSize.width.rounded()),
            height: Int(naturalSize.height.rounded())
        )
        let estimatedFrameCount: Int?
        if nominalFrameRate > 0, durationSeconds.isFinite, durationSeconds > 0 {
            estimatedFrameCount = max(1, Int((nominalFrameRate * durationSeconds).rounded()))
        } else {
            estimatedFrameCount = nil
        }

        // Detect timecode format from video frame rate
        let rawFrameRate = try await track.load(.nominalFrameRate)
        let tcFormat = try TimecodeExtractor.detectFormat(nominalFrameRate: rawFrameRate)

        // Extract timecode from timecode track (falls back to 00:00:00:00)
        let timecodeInfo = try await TimecodeExtractor.extractStartTimecode(from: asset, format: tcFormat)

        // Check for audio
        let hasAudio = try await AudioExtractor.hasAudioTrack(in: asset)

        let summary = ClipMetadataSummary(
            dimensions: dimensions,
            nominalFrameRate: nominalFrameRate > 0 ? nominalFrameRate : nil,
            estimatedFrameCount: estimatedFrameCount,
            manufacturer: metadataDictionary[ColorScience.quickTimeManufacturerKey] as? String,
            model: metadataDictionary[ColorScience.quickTimeModelKey] as? String,
            reportedCaptureCCT: clipColorMetadata.reportedCaptureCCT,
            whiteBalanceByCCTCount: clipColorMetadata.whiteBalanceByCCT.count,
            colorMatrixByCCTCount: clipColorMetadata.colorMatricesByCCT.count
        )

        let precomputedProfile = ColorScience.precomputeClipProfile(clipMetadata: clipColorMetadata)

        return ClipContext(
            asset: asset,
            track: track,
            metadataDictionary: metadataDictionary,
            clipColorMetadata: clipColorMetadata,
            precomputedColorProfile: precomputedProfile,
            summary: summary,
            timecodeInfo: timecodeInfo,
            timecodeFormat: tcFormat,
            hasAudio: hasAudio
        )
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
        compressionPreset _: DNGCompressionPreset
    ) throws -> URL {
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
        dimensions: RasterDimensions?,
        estimatedFrameCount: Int?,
        compressionPreset: DNGCompressionPreset
    ) throws {
        guard let dims = dimensions, let frameCount = estimatedFrameCount, frameCount > 0 else { return }

        let rawBytesPerFrame = dims.width * dims.height * 2
        let compressionFactor: Double = compressionPreset.isLossy ? 0.4 : 0.75
        let estimatedBytes = Int(Double(rawBytesPerFrame) * compressionFactor) * frameCount

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
        request: ConversionRequest,
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

        let clipName = outputFolder.lastPathComponent
        let outputURL = outputFolder.appending(path: "\(clipName)_\(String(format: "%08d", frameIndex)).dng")

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
            compression: request.compressionPreset,
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
        let defaultCropOrigin = [
            max(0, crop?.left ?? 0),
            max(0, crop?.top ?? 0),
        ]
        let defaultCropSize = [
            max(1, Double(visibleWidth) - max(0, crop?.left ?? 0) - max(0, crop?.right ?? 0)),
            max(1, Double(visibleHeight) - max(0, crop?.top ?? 0) - max(0, crop?.bottom ?? 0)),
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
