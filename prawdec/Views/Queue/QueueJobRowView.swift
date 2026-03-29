//
//  QueueJobRowView.swift
//  prawdec
//
//  Created by Codex on 2026/3/28.
//

import SwiftUI

struct QueueJobRowView: View {
    let job: ConversionJob
    var queuePosition: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(job.sourceURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(job.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if job.status == .scanning {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: job.progress.fractionCompleted)
                    .progressViewStyle(.linear)
            }

            HStack {
                Label(job.compressionPreset.title, systemImage: "shippingbox")
                Spacer()
                if job.status == .running {
                    if let speed = job.progress.speedLabel {
                        Text(speed)
                            .monospacedDigit()
                    }
                    Text(job.progress.frameLabel)
                        .monospacedDigit()
                    if let eta = job.progress.etaLabel {
                        Text(eta)
                            .monospacedDigit()
                    }
                } else if job.status == .paused {
                    Text(job.progress.frameLabel)
                        .monospacedDigit()
                } else if job.status == .queued, let position = queuePosition {
                    Text(L10n.tr("queue.position", position))
                } else if let outputFolderURL = job.outputFolderURL {
                    Text(outputFolderURL.lastPathComponent)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let clipMetadata = job.clipMetadata {
                HStack {
                    if let dimensions = clipMetadata.dimensions {
                        Text(dimensions.description)
                    }
                    if let estimatedFrameCount = clipMetadata.estimatedFrameCount {
                        Text(L10n.tr("queue.frames", estimatedFrameCount))
                    }
                    Text(clipMetadata.quality.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch job.status {
        case .completed:
            return .green
        case .failed, .cancelled:
            return .red
        case .running, .preparing:
            return .orange
        case .paused:
            return .blue
        case .pausing, .cancelling:
            return .yellow
        case .queued, .scanning:
            return .gray
        }
    }
}
