//
//  AudiobookshelfDownloadView.swift
//  Listen This Watch App
//
//  Downloads a book straight from the Audiobookshelf server to the Watch, so an
//  offline copy doesn't have to travel through the iPhone.
//

import SwiftData
import SwiftUI
import WatchKit

struct AudiobookshelfDownloadView: View {

    let audiobook: Audiobook

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let manager = AudiobookshelfDownloadManager.shared

    @State private var state: DownloadState = .idle
    @State private var showingBatteryConfirmation = false

    /// Deliberately not named `State`: that shadows SwiftUI's `@State` inside
    /// this view.
    enum DownloadState: Equatable {
        case idle
        case preparing
        case complete
        case error(String)
    }

    /// Below this the Watch risks running flat partway through a large transfer.
    private static let lowBatteryThreshold: Float = 0.2

    var body: some View {
        Group {
            if isConfigured {
                content
            } else {
                notConfiguredView
            }
        }
        .navigationTitle("Download")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                // "Done" while a transfer is running: leaving this screen must
                // not stop the download. Only the red Cancel below does that.
                Button(isTransferring || state == .complete ? "Done" : "Cancel") {
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Low Battery",
            isPresented: $showingBatteryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Download Anyway") { startDownload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Watch battery is low. A large download may drain it before it finishes.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let progress = manager.activeDownloads[audiobook.id] {
            // No header during transfer - maximize space for progress
            ScrollView {
                VStack(spacing: 6) {
                    TransferProgressView(progress: progress) {
                        manager.cancel(audiobookId: audiobook.id)
                        dismiss()
                    }

                    Text("Keeps downloading if you leave this screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
        } else {
            // Scrollable so the book title and explanation stay readable
            // instead of being clipped on a small screen.
            ScrollView {
                VStack(spacing: 8) {
                    switch state {
                    case .idle:
                        header
                        actionCard

                    case .preparing:
                        header
                        ProgressView("Connecting...")
                            .font(.caption)

                    case .complete:
                        completionCard

                    case .error(let message):
                        errorCard(message)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(audiobook.title)
                .font(.footnote)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(
                ByteCountFormatter.string(
                    fromByteCount: audiobook.fileSize,
                    countStyle: .file
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Deliberately spare: the option the user just tapped already said
    /// "Audiobookshelf — Direct from your server", so repeating it here only
    /// costs the vertical space that makes this a one-screen decision.
    private var actionCard: some View {
        Button {
            confirmBatteryThenDownload()
        } label: {
            Text(manager.hasResumeData(for: audiobook.id) ? "Resume" : "Download")
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var completionCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("Downloaded")
                .font(.footnote)
                .fontWeight(.semibold)
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption2)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                state = .idle
            }
            .font(.caption2)
            .controlSize(.small)
        }
    }

    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("Not Configured", systemImage: "iphone.and.arrow.forward")
        } description: {
            Text("Set up Audiobookshelf on your iPhone in Settings.")
        }
    }

    // MARK: - State

    private var isConfigured: Bool {
        SettingsManager.shared.audiobookshelfEnabled
            && SettingsManager.shared.audiobookshelfIsConfigured
    }

    private var isTransferring: Bool {
        manager.activeDownloads[audiobook.id] != nil
    }

    // MARK: - Actions

    /// Warn before committing the Watch to a long transfer on a low battery.
    private func confirmBatteryThenDownload() {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel

        // A negative level means monitoring is unavailable; don't block on it.
        if level >= 0 && level < Self.lowBatteryThreshold {
            showingBatteryConfirmation = true
        } else {
            startDownload()
        }
    }

    private func startDownload() {
        state = .preparing

        Task {
            do {
                manager.configure(modelContext: modelContext)
                _ = try await manager.download(audiobook)
                state = .complete
            } catch AudiobookshelfDownloadError.cancelled {
                dismiss()
            } catch AudiobookshelfDownloadError.alreadyInProgress {
                // Already running (usually re-adopted after the app was
                // suspended) — the progress view takes over from here.
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}

#Preview {
    NavigationStack {
        AudiobookshelfDownloadView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 450_000_000
            )
        )
    }
    .modelContainer(for: [Audiobook.self, CacheEntry.self], inMemory: true)
}
