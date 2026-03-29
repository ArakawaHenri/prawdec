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
                actionButton("开始", systemImage: "play.fill", disabled: !job.canStart) {
                    model.start(jobID: job.id)
                }
                actionButton("暂停", systemImage: "pause.fill", disabled: !job.canPause) {
                    model.pause(jobID: job.id)
                }
                actionButton("取消", systemImage: "xmark.circle.fill", disabled: !job.canCancel) {
                    model.cancel(jobID: job.id)
                }
                actionButton("移除", systemImage: "trash", disabled: !job.canRemove) {
                    model.remove(jobID: job.id)
                }
            }
        }
    }

    private var configurationSection: some View {
        GroupBox("配置") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("输出目录")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(job.outputDirectoryURL.path)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        Button("选择…") {
                            Task { await model.chooseOutputDirectory(for: job.id) }
                        }
                        .disabled(!job.canEditConfiguration)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("压缩模式")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("压缩模式", selection: compressionKindBinding) {
                        ForEach(DNGCompressionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .disabled(!job.canEditConfiguration)

                    if let quality = job.compressionPreset.quality, let range = job.compressionPreset.qualityRange {
                        Stepper(value: compressionQualityBinding, in: range) {
                            Text("质量 \(quality)")
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
        GroupBox("元数据") {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow("状态", job.status.title)
                metadataRow("进度", job.progress.frameLabel)
                if let speed = job.progress.speedLabel, job.status == .running {
                    metadataRow("速度", speed)
                }
                if let eta = job.progress.etaLabel, job.status == .running {
                    metadataRow("剩余时间", eta)
                }
                if let clipMetadata = job.clipMetadata {
                    if let dimensions = clipMetadata.dimensions {
                        metadataRow("尺寸", dimensions.description)
                    }
                    if let nominalFrameRate = clipMetadata.nominalFrameRate {
                        metadataRow("帧率", String(format: "%.3f", nominalFrameRate))
                    }
                    if let estimatedFrameCount = clipMetadata.estimatedFrameCount {
                        metadataRow("估计帧数", "\(estimatedFrameCount)")
                    }
                    metadataRow("元数据质量", clipMetadata.quality.title)
                    if let manufacturer = clipMetadata.manufacturer {
                        metadataRow("厂商", manufacturer)
                    }
                    if let model = clipMetadata.model {
                        metadataRow("机型", model)
                    }
                    if let reportedCaptureCCT = clipMetadata.reportedCaptureCCT {
                        metadataRow("拍摄白平衡", "\(reportedCaptureCCT)K")
                    }
                    metadataRow("WB ByCCT", "\(clipMetadata.whiteBalanceByCCTCount)")
                    metadataRow("矩阵 ByCCT", "\(clipMetadata.colorMatrixByCCTCount)")
                } else {
                    Text("尚未取得 clip 元数据。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var runtimeSection: some View {
        GroupBox("运行时") {
            VStack(alignment: .leading, spacing: 10) {
                metadataRow("创建时间", formatted(job.createdAt))
                if let startedAt = job.startedAt {
                    metadataRow("开始时间", formatted(startedAt))
                }
                if let finishedAt = job.finishedAt {
                    metadataRow("完成时间", formatted(finishedAt))
                }
                if let note = job.note, !note.isEmpty {
                    metadataRow("备注", note)
                }
                if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                    metadataRow("错误", errorMessage)
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
                        Button("在 Finder 中显示") {
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
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
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

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
