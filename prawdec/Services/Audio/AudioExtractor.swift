//
//  AudioExtractor.swift
//  prawdec
//
//  Extracts audio from QuickTime to WAV sidecar for CinemaDNG.
//

import AVFoundation
import AudioToolbox
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
    private static func makeChannelLayoutData(
        formatDescription: CMAudioFormatDescription,
        channelCount: UInt32
    ) -> Data {
        var layoutSize = 0
        if let layoutPointer = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize),
           layoutSize > 0
        {
            return Data(bytes: layoutPointer, count: layoutSize)
        }

        var fallbackLayout = AudioChannelLayout()
        switch channelCount {
        case 1:
            fallbackLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2:
            fallbackLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        default:
            fallbackLayout.mChannelLayoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | channelCount)
        }
        fallbackLayout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        fallbackLayout.mNumberChannelDescriptions = 0

        return withUnsafePointer(to: &fallbackLayout) { pointer in
            Data(bytes: pointer, count: MemoryLayout<AudioChannelLayout>.size)
        }
    }

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
        let channelLayoutData = makeChannelLayoutData(
            formatDescription: formatDesc,
            channelCount: channelCount
        )

        let writer = try AVAssetWriter(url: outputURL, fileType: .wav)
        let writerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVChannelLayoutKey: channelLayoutData,
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
        guard writer.startWriting() else {
            throw AudioExtractorError.exportFailed(writer.error?.localizedDescription ?? L10n.tr("error.audio.write_failed"))
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "moe.henri.prawdec.audio")
            var didResume = false

            func resume(with result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        guard writerInput.append(sampleBuffer) else {
                            writerInput.markAsFinished()
                            let message = writer.error?.localizedDescription
                                ?? reader.error?.localizedDescription
                                ?? L10n.tr("error.audio.write_failed")
                            resume(with: .failure(AudioExtractorError.exportFailed(message)))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            let message = reader.error?.localizedDescription ?? L10n.tr("error.audio.cannot_start_reading")
                            resume(with: .failure(AudioExtractorError.exportFailed(message)))
                        } else if reader.status == .cancelled {
                            resume(with: .failure(AudioExtractorError.exportFailed(L10n.tr("error.conversion.cancelled"))))
                        } else {
                            resume(with: .success(()))
                        }
                        return
                    }
                }

                if reader.status == .failed {
                    let message = reader.error?.localizedDescription ?? L10n.tr("error.audio.cannot_start_reading")
                    resume(with: .failure(AudioExtractorError.exportFailed(message)))
                } else if writer.status == .failed {
                    let message = writer.error?.localizedDescription ?? L10n.tr("error.audio.write_failed")
                    resume(with: .failure(AudioExtractorError.exportFailed(message)))
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw AudioExtractorError.exportFailed(writer.error?.localizedDescription ?? L10n.tr("error.audio.write_failed"))
        }
    }
}
