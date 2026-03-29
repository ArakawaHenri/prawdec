//
//  TimecodeExtractor.swift
//  prawdec
//
//  Extracts timecode from QuickTime timecode tracks and computes
//  per-frame SMPTE timecodes for CinemaDNG output.
//

import AVFoundation
import CoreMedia
import Foundation

struct TimecodeInfo: Sendable {
    var startTimecode: SMPTETimecode
    var format: TimecodeFormat
}

enum TimecodeExtractorError: LocalizedError, Sendable {
    case unsupportedFrameRate(Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedFrameRate(let fps):
            return L10n.tr("error.timecode_extractor.unsupported_frame_rate", fps)
        }
    }
}

enum TimecodeExtractor {

    /// Detect the `TimecodeFormat` for a video track's frame rate.
    static func detectFormat(nominalFrameRate: Float, dropFrame: Bool = false) throws -> TimecodeFormat {
        let fps = Double(nominalFrameRate)
        do {
            return try TimecodeFormat.detect(from: fps, dropFrame: dropFrame)
        } catch {
            throw TimecodeExtractorError.unsupportedFrameRate(fps)
        }
    }

    /// Extract the starting timecode from the asset's timecode track.
    /// Returns nil if no timecode track is present.
    static func extractStartTimecode(
        from asset: AVURLAsset,
        format: TimecodeFormat
    ) async throws -> TimecodeInfo? {
        let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
        guard let tcTrack = timecodeTracks.first else {
            return nil
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tcTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            return nil
        }

        // Timecode sample buffers contain a frame number as a big-endian Int32
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                  lengthAtOffsetOut: &length,
                                                  totalLengthOut: nil,
                                                  dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length >= 4 else {
            return nil
        }

        let frameNumber = ptr.withMemoryRebound(to: Int32.self, capacity: 1) {
            Int(Int32(bigEndian: $0.pointee))
        }

        // Check for drop-frame flag in the timecode format description
        var actualFormat = format
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(formatDescription)
            if flags & UInt32(kCMTimeCodeFlag_DropFrame) != 0 {
                actualFormat = try format.withDropFrame(true)
            }
        }

        let tc = SMPTETimecode(frameNumber: frameNumber, format: actualFormat)
        return TimecodeInfo(startTimecode: tc, format: actualFormat)
    }

    /// Compute the timecode for a specific frame index.
    static func timecodeForFrame(
        startTimecode: SMPTETimecode,
        frameIndex: Int
    ) -> SMPTETimecode {
        startTimecode.advanced(by: frameIndex)
    }

    /// Default start timecode (00:00:00:00) when no timecode track exists.
    static func defaultStartTimecode(format: TimecodeFormat) -> TimecodeInfo {
        TimecodeInfo(
            startTimecode: SMPTETimecode(hours: 0, minutes: 0, seconds: 0, frames: 0, format: format),
            format: format
        )
    }
}
