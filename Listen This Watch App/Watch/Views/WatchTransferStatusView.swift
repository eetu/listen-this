//
//  WatchTransferStatusView.swift
//  Listen This Watch App
//
//  Shows transfer status and allows requesting downloads from iPhone
//

import SwiftData
import SwiftUI

struct WatchTransferStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(WatchConnectivityManager.self) private var connectivity

    let audiobook: Audiobook

    @State private var isRequesting = false

    private var hasActiveTransfer: Bool {
        connectivity.activeTransfers[audiobook.id.uuidString] != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Only show audiobook info when NOT transferring
                if !hasActiveTransfer {
                    audiobookInfo
                }

                // Transfer status
                if let transfer = connectivity.activeTransfers[audiobook.id.uuidString] {
                    activeTransferView(transfer)
                } else if audiobook.isFileCached {
                    cachedView
                } else {
                    downloadOptions
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(hasActiveTransfer ? audiobook.title : "Download")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Audiobook Info (only shown when not transferring)

    private var audiobookInfo: some View {
        VStack(spacing: 8) {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData)
            {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(spacing: 2) {
                Text(audiobook.title)
                    .font(.footnote)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(audiobook.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)

                if audiobook.fileSize > 0 {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: audiobook.fileSize, countStyle: .file)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Active Transfer

    private func activeTransferView(_ transfer: TransferProgress) -> some View {
        VStack(spacing: 6) {
            // Compact circular progress with percentage
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 5)
                    .frame(width: 60, height: 60)
                
                Circle()
                    .trim(from: 0, to: transfer.progress)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                    .animation(
                        isLuminanceReduced ? nil : .easeInOut(duration: 0.3),
                        value: transfer.progress
                    )
                
                Text("\(transfer.progressPercentage)%")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
            
            // Bytes + time in single line
            HStack(spacing: 4) {
                Text(transfer.progressText)
                if let remaining = transfer.estimatedTimeRemaining,
                   remaining > 0, remaining.isFinite {
                    Text("·")
                    Text(formatTimeRemaining(remaining))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            // Cancel button - compact
            Button(role: .destructive) {
                connectivity.cancelTransfer(audiobookId: audiobook.id)
            } label: {
                Text("Cancel")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
    
    // MARK: - Helpers
    
    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "< 1 min left"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60)) min left"
        } else {
            let hours = Int(seconds / 3600)
            let mins = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            return mins > 0 ? "\(hours)h \(mins)m left" : "\(hours)h left"
        }
    }

    // MARK: - Cached View

    private var cachedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("Downloaded")
                .font(.headline)

            Text("Ready to play")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                dismiss()
            } label: {
                Text("Done")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }

    // MARK: - Download Options

    private var downloadOptions: some View {
        VStack(spacing: 12) {
            if connectivity.isReachable {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.right.outward")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)

                    Text("Download from iPhone")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Transfer to play offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        requestDownload()
                    } label: {
                        if isRequesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Download")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequesting)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)

                    Text("iPhone Not Connected")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Keep iPhone nearby")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Error display - compact
            if let error = connectivity.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Actions

    private func requestDownload() {
        isRequesting = true

        Task {
            connectivity.requestDownload(audiobookId: audiobook.id)

            // Wait a moment for the transfer to start
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

            await MainActor.run {
                isRequesting = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        WatchTransferStatusView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 500_000_000
            )
        )
    }
    .environment(WatchConnectivityManager.shared)
}
