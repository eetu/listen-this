//
//  TransferProgressView.swift
//  Listen This
//
//  Shared progress display for long file transfers (CloudKit chunks and
//  Audiobookshelf downloads), so every transfer looks the same on each platform.
//

import SwiftUI

struct TransferProgressView: View {

    let progress: ChunkTransferProgress
    let onCancel: () -> Void

    var body: some View {
        #if os(watchOS)
            watchLayout
        #else
            phoneLayout
        #endif
    }

    // MARK: - Watch

    private var watchLayout: some View {
        VStack(spacing: 4) {
            // Larger circular progress for Watch - fills available space
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 6)

                Circle()
                    .trim(from: 0, to: progress.progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress.progress)

                VStack(spacing: 0) {
                    Text("\(progress.progressPercentage)%")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()

                    // Speed inside circle
                    if !progress.speedText.isEmpty {
                        Text(progress.speedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(width: 90, height: 90)

            if progress.usesByteProgress {
                Text(progress.progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("\(progress.completedChunks)/\(progress.totalChunks)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button("Cancel", role: .destructive, action: onCancel)
                .font(.caption2)
                .controlSize(.small)
        }
    }

    // MARK: - iPhone / iPad

    private var phoneLayout: some View {
        VStack(spacing: 16) {
            // Progress circle with percentage
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.2), lineWidth: 10)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: progress.progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress.progress)

                VStack(spacing: 2) {
                    Text("\(progress.progressPercentage)%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    if !progress.speedText.isEmpty {
                        Text(progress.speedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            // Transfer details
            VStack(spacing: 8) {
                HStack {
                    Text("Transferred")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.progressText)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .font(.subheadline)

                // Chunk counts are meaningless for a single-stream download.
                if !progress.usesByteProgress {
                    HStack {
                        Text("Chunks")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(progress.completedChunks) / \(progress.totalChunks)")
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }

                if let timeRemaining = progress.estimatedTimeRemainingText {
                    HStack {
                        Text("Remaining")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeRemaining)
                            .fontWeight(.medium)
                    }
                    .font(.subheadline)
                }
            }

            Button("Cancel Transfer", role: .destructive, action: onCancel)
                .controlSize(.large)
        }
        .padding(20)
        #if os(iOS)
            .background(Color(.systemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        #endif
    }
}

#Preview("Chunked") {
    TransferProgressView(
        progress: ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 500_000_000,
            totalChunks: 5,
            completedChunks: 2,
            bytesTransferred: 200_000_000,
            isUploading: false
        ),
        onCancel: {}
    )
}

#Preview("Single stream") {
    TransferProgressView(
        progress: ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 500_000_000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 175_000_000,
            isUploading: false,
            usesByteProgress: true
        ),
        onCancel: {}
    )
}
