//
//  JobDetailView.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import SwiftUI

struct JobDetailView: View {
    @Bindable var model: AppModel
    let job: ConversionJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                configurationSection
                metadataSection
                videoTracksSection
                audioTracksSection
                runtimeSection
            }
            .padding(20)
        }
        .frame(minWidth: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.displayName)
                .font(.title2.weight(.semibold))
            Text(job.sourceURL.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                actionButton(L10n.tr("action.start"), systemImage: "play.fill", disabled: !job.canStart) {
                    model.start(jobID: job.id)
                }
                actionButton(L10n.tr("action.pause"), systemImage: "pause.fill", disabled: !job.canPause) {
                    model.pause(jobID: job.id)
                }
                actionButton(L10n.tr("action.cancel"), systemImage: "xmark.circle.fill", disabled: !job.canCancel) {
                    model.cancel(jobID: job.id)
                }
                actionButton(L10n.tr("action.remove"), systemImage: "trash", disabled: !job.canRemove) {
                    model.remove(jobID: job.id)
                }
            }
        }
    }

    private var configurationSection: some View {
        GroupBox(L10n.tr("section.configuration")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("field.output_directory"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(job.outputDirectoryURL.path)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button(L10n.tr("action.select_ellipsis")) {
                            Task { await model.chooseOutputDirectory(for: job.id) }
                        }
                        .disabled(!job.canEditConfiguration)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("field.compression_mode"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker(L10n.tr("field.compression_mode"), selection: compressionKindBinding) {
                        ForEach(DNGCompressionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .disabled(!job.canEditConfiguration)

                    if let quality = job.compressionPreset.quality, let range = job.compressionPreset.qualityRange {
                        Stepper(value: compressionQualityBinding, in: range) {
                            Text(L10n.tr("field.quality", quality))
                        }
                        .disabled(!job.canEditConfiguration)
                    }

                    Text(job.compressionPreset.shortDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var metadataSection: some View {
        GroupBox(L10n.tr("section.metadata")) {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(L10n.tr("field.status"), job.status.title)
                metadataRow(L10n.tr("field.progress"), job.progress.frameLabel)
                if let speed = job.progress.speedLabel, job.status == .running {
                    metadataRow(L10n.tr("field.speed"), speed)
                }
                if let eta = job.progress.etaLabel, job.status == .running {
                    metadataRow(L10n.tr("field.eta"), eta)
                }
                if let sourceMetadata = job.sourceMetadata {
                    metadataRow(L10n.tr("field.metadata_quality"), sourceMetadata.quality.title)
                    metadataRow(L10n.tr("field.video_track_count"), "\(sourceMetadata.videoTrackCount)")
                    metadataRow(L10n.tr("field.audio_track_count"), "\(sourceMetadata.audioTrackCount)")
                    metadataRow(L10n.tr("field.timecode_track_count"), "\(sourceMetadata.timecodeTrackCount)")
                    if let manufacturer = sourceMetadata.manufacturer {
                        metadataRow(L10n.tr("field.manufacturer"), manufacturer)
                    }
                    if let model = sourceMetadata.model {
                        metadataRow(L10n.tr("field.model"), model)
                    }
                    if let reportedCaptureCCT = sourceMetadata.reportedCaptureCCT {
                        metadataRow(L10n.tr("field.capture_white_balance"), L10n.tr("value.capture_white_balance", reportedCaptureCCT))
                    }
                    metadataRow(L10n.tr("field.wb_bycct"), "\(sourceMetadata.whiteBalanceByCCTCount)")
                    metadataRow(L10n.tr("field.matrix_bycct"), "\(sourceMetadata.colorMatrixByCCTCount)")
                } else {
                    Text(L10n.tr("metadata.unavailable"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var videoTracksSection: some View {
        GroupBox(L10n.tr("section.video_tracks")) {
            VStack(alignment: .leading, spacing: 12) {
                if job.videoTracks.isEmpty {
                    Text(L10n.tr("metadata.unavailable"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(job.videoTracks) { track in
                        trackCard(title: track.track.displayName, status: track.status) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let dimensions = track.summary.dimensions {
                                    metadataRow(L10n.tr("field.dimensions"), dimensions.description)
                                }
                                if let frameRate = track.summary.nominalFrameRate {
                                    metadataRow(L10n.tr("field.frame_rate"), L10n.tr("value.frame_rate", frameRate))
                                }
                                if let estimatedFrames = track.summary.estimatedFrameCount {
                                    metadataRow(L10n.tr("field.estimated_frames"), "\(estimatedFrames)")
                                }
                                metadataRow(L10n.tr("field.progress"), track.progress.frameLabel)
                                if let timecode = track.selectedTimecodeOption?.startTimecode {
                                    metadataRow(L10n.tr("field.start_timecode"), timecode)
                                }
                                if track.canChooseTimecode {
                                    Picker(
                                        L10n.tr("field.timecode_track"),
                                        selection: videoTimecodeBinding(for: track.track.trackID)
                                    ) {
                                        ForEach(track.availableTimecodeOptions) { option in
                                            Text(option.title).tag(Optional(option.track.trackID))
                                        }
                                    }
                                    .disabled(!job.canEditConfiguration)
                                }
                                if let note = track.note, !note.isEmpty {
                                    metadataRow(L10n.tr("field.note"), note)
                                }
                                if let errorMessage = track.errorMessage, !errorMessage.isEmpty {
                                    metadataRow(L10n.tr("field.error"), errorMessage)
                                }
                                ForEach(track.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var audioTracksSection: some View {
        GroupBox(L10n.tr("section.audio_tracks")) {
            VStack(alignment: .leading, spacing: 12) {
                if job.audioTracks.isEmpty {
                    Text(L10n.tr("field.no_audio_tracks"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(job.audioTracks) { track in
                        trackCard(title: track.track.displayName, status: track.status) {
                            VStack(alignment: .leading, spacing: 8) {
                                metadataRow(L10n.tr("field.output_file"), track.outputFileName)
                                metadataRow(L10n.tr("field.progress"), track.progress.frameLabel)
                                if let timecode = track.selectedTimecodeOption?.startTimecode {
                                    metadataRow(L10n.tr("field.start_timecode"), timecode)
                                }
                                if track.canChooseTimecode {
                                    Picker(
                                        L10n.tr("field.timecode_track"),
                                        selection: audioTimecodeBinding(for: track.track.trackID)
                                    ) {
                                        ForEach(track.availableTimecodeOptions) { option in
                                            Text(option.title).tag(Optional(option.track.trackID))
                                        }
                                    }
                                    .disabled(!job.canEditConfiguration)
                                }
                                if let note = track.note, !note.isEmpty {
                                    metadataRow(L10n.tr("field.note"), note)
                                }
                                if let errorMessage = track.errorMessage, !errorMessage.isEmpty {
                                    metadataRow(L10n.tr("field.error"), errorMessage)
                                }
                                ForEach(track.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.callout)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var runtimeSection: some View {
        GroupBox(L10n.tr("section.runtime")) {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(L10n.tr("field.created_at"), formatted(job.createdAt))
                if let startedAt = job.startedAt {
                    metadataRow(L10n.tr("field.started_at"), formatted(startedAt))
                }
                if let finishedAt = job.finishedAt {
                    metadataRow(L10n.tr("field.finished_at"), formatted(finishedAt))
                }
                if let note = job.note, !note.isEmpty {
                    metadataRow(L10n.tr("field.note"), note)
                }
                if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                    metadataRow(L10n.tr("field.error"), errorMessage)
                }
                if !job.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(job.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let outputFolderURL = job.outputFolderURL {
                    HStack {
                        Text(outputFolderURL.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button(L10n.tr("action.reveal_in_finder")) {
                            model.revealOutputFolder(for: job.id)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func trackCard<Content: View>(title: String, status: ConversionStatus, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actionButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }

    private var compressionKindBinding: Binding<DNGCompressionKind> {
        Binding(
            get: { job.compressionPreset.kind },
            set: { model.updateCompressionKind($0, for: job.id) }
        )
    }

    private var compressionQualityBinding: Binding<Int> {
        Binding(
            get: { job.compressionPreset.quality ?? DNGCompressionQualityDefaults.jpegQuality },
            set: { model.updateCompressionQuality($0, for: job.id) }
        )
    }

    private func videoTimecodeBinding(for trackID: Int32) -> Binding<Int32?> {
        Binding(
            get: { job.videoTracks.first(where: { $0.track.trackID == trackID })?.selectedTimecodeTrackID },
            set: { model.updateVideoTimecodeTrack($0, for: trackID, in: job.id) }
        )
    }

    private func audioTimecodeBinding(for trackID: Int32) -> Binding<Int32?> {
        Binding(
            get: { job.audioTracks.first(where: { $0.track.trackID == trackID })?.selectedTimecodeTrackID },
            set: { model.updateAudioTimecodeTrack($0, for: trackID, in: job.id) }
        )
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
