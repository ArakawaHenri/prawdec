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

struct TimecodeSampleRun: Sendable {
    var sourceStart: CMTime
    var duration: CMTime
    var frameNumber: Int
}

struct TimecodeTrackSnapshot: Sendable {
    var descriptor: MediaTrackDescriptor
    var format: TimecodeFormat
    var segments: [AVAssetTrackSegment]
    var sampleRuns: [TimecodeSampleRun]
}

struct TimecodeInfo: Sendable {
    var startTimecode: SMPTETimecode
    var format: TimecodeFormat
}

enum TimecodeExtractorError: LocalizedError, Sendable {
    case unsupportedFrameRate(Double)
    case invalidTimecodeTrack

    var errorDescription: String? {
        switch self {
        case .unsupportedFrameRate(let fps):
            return L10n.tr("error.timecode_extractor.unsupported_frame_rate", fps)
        case .invalidTimecodeTrack:
            return L10n.tr("error.timecode_extractor.invalid_timecode_track")
        }
    }
}

enum TimecodeExtractor {

    static func formatFromDescription(_ formatDescription: CMFormatDescription) throws -> TimecodeFormat {
        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(formatDescription)
        let frameQuanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(formatDescription))
        let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(formatDescription)
        let isDropFrame = (flags & UInt32(kCMTimeCodeFlag_DropFrame)) != 0

        guard frameDuration.isValid, frameDuration.value > 0, frameDuration.timescale > 0 else {
            throw TimecodeExtractorError.invalidTimecodeTrack
        }

        let numerator = Int32(frameDuration.timescale)
        let denominator = Int32(frameDuration.value)
        return try TimecodeFormat(
            frameRateNumerator: numerator,
            frameRateDenominator: denominator,
            nominalFPS: frameQuanta,
            dropFrame: isDropFrame
        )
    }

    static func loadSnapshot(
        from asset: AVURLAsset,
        track: AVAssetTrack,
        descriptor: MediaTrackDescriptor
    ) async throws -> TimecodeTrackSnapshot {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else {
            throw TimecodeExtractorError.invalidTimecodeTrack
        }

        let format = try formatFromDescription(formatDescription)
        let segments = try await track.load(.segments)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw TimecodeExtractorError.invalidTimecodeTrack
        }

        reader.add(output)
        guard reader.startReading() else {
            throw TimecodeExtractorError.invalidTimecodeTrack
        }

        var sampleRuns: [TimecodeSampleRun] = []
        var sourceCursor = CMTime.zero

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let duration = CMSampleBufferGetDuration(sampleBuffer)
            let normalizedDuration: CMTime
            if duration.isValid, duration.value > 0 {
                normalizedDuration = duration
            } else {
                normalizedDuration = .zero
            }

            defer {
                if normalizedDuration.isValid, normalizedDuration.value > 0 {
                    sourceCursor = CMTimeAdd(sourceCursor, normalizedDuration)
                }
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var length: Int = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &length,
                totalLengthOut: nil,
                dataPointerOut: &dataPointer
            )

            guard status == kCMBlockBufferNoErr, let dataPointer, length >= 4 else {
                continue
            }

            let frameNumber = dataPointer.withMemoryRebound(to: Int32.self, capacity: 1) {
                Int(Int32(bigEndian: $0.pointee))
            }

            sampleRuns.append(
                TimecodeSampleRun(
                    sourceStart: sourceCursor,
                    duration: normalizedDuration,
                    frameNumber: frameNumber
                )
            )
        }

        return TimecodeTrackSnapshot(
            descriptor: descriptor,
            format: format,
            segments: segments,
            sampleRuns: sampleRuns
        )
    }

    static func firstMovieTime(for track: AVAssetTrack) async throws -> CMTime? {
        let segments = try await track.load(.segments)
            .filter { !$0.isEmpty }
            .sorted { CMTimeCompare($0.timeMapping.target.start, $1.timeMapping.target.start) < 0 }
        return segments.first?.timeMapping.target.start
    }

    static func sourceTime(forMovieTime movieTime: CMTime, in segments: [AVAssetTrackSegment]) -> CMTime? {
        for segment in segments where !segment.isEmpty {
            let target = segment.timeMapping.target
            let targetEnd = CMTimeAdd(target.start, target.duration)
            let startsBeforeEnd = CMTimeCompare(movieTime, targetEnd) < 0
            let startsAfterOrAtStart = CMTimeCompare(movieTime, target.start) >= 0
            guard startsAfterOrAtStart, startsBeforeEnd else { continue }

            let offset = CMTimeSubtract(movieTime, target.start)
            let targetSeconds = CMTimeGetSeconds(target.duration)
            let sourceSeconds = CMTimeGetSeconds(segment.timeMapping.source.duration)

            guard targetSeconds.isFinite, targetSeconds > 0, sourceSeconds.isFinite else {
                return segment.timeMapping.source.start
            }

            let scaledOffset = sourceSeconds == 0
                ? 0
                : (CMTimeGetSeconds(offset) / targetSeconds) * sourceSeconds
            let offsetTime = CMTime(
                seconds: scaledOffset,
                preferredTimescale: max(segment.timeMapping.source.duration.timescale, 600)
            )
            return CMTimeAdd(segment.timeMapping.source.start, offsetTime)
        }

        return nil
    }

    static func resolveStartTimecode(
        for mediaTrack: AVAssetTrack,
        using snapshot: TimecodeTrackSnapshot
    ) async throws -> SMPTETimecode? {
        guard let movieStartTime = try await firstMovieTime(for: mediaTrack) else {
            return nil
        }
        guard let timecodeSourceTime = sourceTime(forMovieTime: movieStartTime, in: snapshot.segments) else {
            return nil
        }
        guard let run = sampleRun(containing: timecodeSourceTime, in: snapshot.sampleRuns) else {
            return nil
        }

        let offset = CMTimeSubtract(timecodeSourceTime, run.sourceStart)
        let offsetFrames = frameOffset(for: offset, nominalFPS: snapshot.format.nominalFPS)
        return SMPTETimecode(frameNumber: run.frameNumber + offsetFrames, format: snapshot.format)
    }

    private static func sampleRun(
        containing sourceTime: CMTime,
        in runs: [TimecodeSampleRun]
    ) -> TimecodeSampleRun? {
        guard let firstRun = runs.first else {
            return nil
        }
        if CMTimeCompare(sourceTime, firstRun.sourceStart) < 0 {
            return nil
        }

        var lastRangedRun: TimecodeSampleRun?
        for run in runs {
            let duration = run.duration
            if duration == .zero {
                if CMTimeCompare(sourceTime, run.sourceStart) == 0 {
                    return run
                }
                continue
            }

            let end = CMTimeAdd(run.sourceStart, duration)
            if CMTimeCompare(sourceTime, run.sourceStart) >= 0,
               CMTimeCompare(sourceTime, end) < 0 {
                return run
            }
            if CMTimeCompare(sourceTime, run.sourceStart) >= 0 {
                lastRangedRun = run
            }
        }
        return lastRangedRun
    }

    private static func frameOffset(for duration: CMTime, nominalFPS: Int) -> Int {
        let rawFrames = CMTimeGetSeconds(duration) * Double(nominalFPS)
        guard rawFrames.isFinite else {
            return 0
        }
        return max(0, Int(floor(rawFrames + 1e-6)))
    }

    /// Detect the `TimecodeFormat` for a video track's frame rate.
    static func detectFormat(nominalFrameRate: Float, dropFrame: Bool = false) throws -> TimecodeFormat {
        let fps = Double(nominalFrameRate)
        do {
            return try TimecodeFormat.detect(from: fps, dropFrame: dropFrame)
        } catch {
            throw TimecodeExtractorError.unsupportedFrameRate(fps)
        }
    }

    /// Compute the timecode for a specific frame index.
    static func timecodeForFrame(
        startTimecode: SMPTETimecode,
        frameIndex: Int
    ) -> SMPTETimecode {
        startTimecode.advanced(by: frameIndex)
    }
}
