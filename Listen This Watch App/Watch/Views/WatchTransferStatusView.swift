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
    @Environment(WatchConnectivityManager.self) private var connectivity

    let audiobook: Audiobook

    @State private var isRequesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Audiobook info
                audiobookInfo

                // Transfer status
                if let transfer = connectivity.activeTransfers[audiobook.id.uuidString] {
                    activeTransferView(transfer)
                } else if audiobook.isFileCached {
                    cachedView
                } else {
                    downloadOptions
                }
            }
            .padding()
        }
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Audiobook Info

    private var audiobookInfo: some View {
        VStack(spacing: 12) {
            if let artworkData = audiobook.artworkData,
                let uiImage = UIImage(data: artworkData)
            {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            VStack(spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if audiobook.fileSize > 0 {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: audiobook.fileSize, countStyle: .file)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Active Transfer

    private func activeTransferView(_ transfer: TransferProgress) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)

                Text("Downloading...")
                    .font(.headline)

                Text("Keep your iPhone nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(role: .destructive) {
                connectivity.cancelTransfer(audiobookId: audiobook.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Cached View

    private var cachedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("Downloaded")
                .font(.headline)

            Text("This audiobook is ready to play")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Download Options

    private var downloadOptions: some View {
        VStack(spacing: 16) {
            if connectivity.isReachable {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.and.arrow.right.outward")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    Text("Download from iPhone")
                        .font(.headline)

                    Text("Transfer this audiobook from your iPhone to play offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        requestDownload()
                    } label: {
                        if isRequesting {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Requesting...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("Request Download")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequesting)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)

                    Text("iPhone Not Connected")
                        .font(.headline)

                    Text("Make sure your iPhone is nearby and unlocked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // Error display
            if let error = connectivity.lastError {
                VStack(spacing: 4) {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)

                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)
            }
        }
        .padding()
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
