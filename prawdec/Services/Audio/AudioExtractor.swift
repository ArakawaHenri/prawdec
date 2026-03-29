//
//  AudioExtractor.swift
//  prawdec
//
//  Extracts audio from QuickTime to WAV sidecar for CinemaDNG.
//

import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError, Sendable {
    case noAudioTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return L10n.tr("error.audio.no_audio_track")
        case .exportFailed(let message):
            return L10n.tr("error.audio.export_failed", message)
        }
    }
}

enum AudioExtractor {

    /// Check whether the asset has an audio track.
    static func hasAudioTrack(in asset: AVURLAsset) async throws -> Bool {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        return !tracks.isEmpty
    }

    /// Extract audio from the asset to a WAV file at the given URL.
    /// Uses AVAssetReader + AVAssetWriter for PCM WAV output.
    static func extractAudio(from asset: AVURLAsset, to outputURL: URL) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioExtractorError.noAudioTrack
        }

        // Remove existing file if present
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw AudioExtractorError.exportFailed(L10n.tr("error.audio.cannot_add_reader_output"))
        }
        reader.add(readerOutput)

        // Get audio properties from the reader output
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let formatDesc = formatDescriptions.first else {
            throw AudioExtractorError.exportFailed(L10n.tr("error.audio.cannot_get_format_description"))
        }
        let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        let sampleRate = basicDesc?.pointee.mSampleRate ?? 48000
        let channelCount = basicDesc?.pointee.mChannelsPerFrame ?? 2

        let writer = try AVAssetWriter(url: outputURL, fileType: .wav)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw AudioExtractorError.exportFailed(L10n.tr("error.audio.cannot_add_writer_input"))
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioExtractorError.exportFailed(reader.error?.localizedDescription ?? L10n.tr("error.audio.cannot_start_reading"))
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "moe.henri.prawdec.audio")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw AudioExtractorError.exportFailed(writer.error?.localizedDescription ?? L10n.tr("error.audio.write_failed"))
        }
    }
}
