//
//  AutoTransferSheet.swift
//  Listen This
//
//  Sheet for automatically selecting and initiating audiobook transfer to Watch
//

import SwiftData
import SwiftUI

struct AutoTransferSheet: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selector: TransferMethodSelector?
    @State private var selectedMethod: SelectedMethod?
    @State private var completedMethod: SelectedMethod?
    @State private var isTransferring = false
    @State private var transferError: Error?
    @State private var showError = false
    @State private var cloudKitManager: CloudKitChunkedTransferManager?
    @State private var presence = SheetPresence()

    /// Whether leaving abandons nothing, which decides the dismiss button's
    /// meaning (see the toolbar).
    private var canOnlyAcknowledge: Bool {
        if isTransferring || completedMethod != nil { return true }
        if case .error = selectedMethod { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            if let completedMethod {
                completionView(completedMethod)
            } else if let selectedMethod {
                methodHeader(selectedMethod)

                if isTransferring {
                    transferProgressView
                } else if let action = startTitle(selectedMethod) {
                    VStack(spacing: 12) {
                        Button {
                            Task { await performTransfer() }
                        } label: {
                            Text(action)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(methodColor(selectedMethod))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        if let alternative = alternativeMethod(to: selectedMethod) {
                            Button(alternativeTitle(alternative)) {
                                self.selectedMethod = alternative
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                ProgressView("Choosing how to send...")
            }
        }
        .navigationTitle("Send to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Placements are semantic: before starting, leaving abandons the
            // transfer (a cancellation); once running or finished, the transfer
            // carries on regardless, so leaving is an acknowledgement.
            if canOnlyAcknowledge {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert("Transfer Failed", isPresented: $showError) {
            Button("Try Again") {
                Task { await performTransfer() }
            }
            Button("OK", role: .cancel) {
                transferError = nil
            }
        } message: {
            if let error = transferError {
                Text(error.localizedDescription)
            }
        }
        .task {
            if selector == nil {
                let newSelector = TransferMethodSelector(modelContext: modelContext)
                selector = newSelector
                selectedMethod = await newSelector.selectMethod(for: audiobook)

                // Initialize CloudKit manager for progress tracking
                cloudKitManager = CloudKitChunkedTransferManager(modelContext: modelContext)
            }
        }
        .onAppear { presence.isVisible = true }
        .onDisappear { presence.isVisible = false }
    }

    // MARK: - Sections

    private func methodHeader(_ method: SelectedMethod) -> some View {
        VStack(spacing: 12) {
            Image(systemName: methodIcon(method))
                .font(.system(size: 48))
                .foregroundStyle(methodColor(method))

            Text(methodTitle(method))
                .font(.title3)
                .fontWeight(.semibold)

            Text(methodSummary(method))
                .font(.subheadline)
                .multilineTextAlignment(.center)

            if let reason = method.reason, !reason.isEmpty {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var transferProgressView: some View {
        if let manager = cloudKitManager, let progress = manager.activeUploads[audiobook.id] {
            TransferProgressView(progress: progress, cancelTitle: "Cancel Upload") {
                manager.cancelTransfer(audiobookId: audiobook.id)
            }
            .padding(.horizontal)
        } else if let fraction = TransferProgressCenter.shared.fraction(for: audiobook.id) {
            // The book is coming down from iCloud Drive before it can be sent
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                Text("Downloading from iCloud Drive, \(Int(fraction * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 32)
        } else {
            // Fetching the file from iCloud Drive or queueing a direct transfer
            ProgressView("Preparing...")
                .padding()
        }
    }

    /// What happens next, so the sheet never just closes on the user.
    private func completionView(_ method: SelectedMethod) -> some View {
        let title = audiobook.title
        let (icon, heading, detail): (String, String, String) =
            switch method {
            case .cloudKit, .alreadyUploaded:
                (
                    "checkmark.icloud", "Ready in iCloud",
                    "Open Listen This on your Watch and it downloads \"\(title)\" over Wi-Fi."
                )
            case .watchConnectivity:
                (
                    "applewatch", "Sending to Watch",
                    "This keeps going in the background, so you can close this. \"\(title)\" appears on your Watch when it arrives, and you'll be told here if it fails."
                )
            case .iCloudDirect:
                ("checkmark.circle", "Downloaded to iPhone", "\"\(title)\" is ready on this iPhone.")
            case .error(let reason):
                ("exclamationmark.triangle", "Can't Send", reason)
            }

        return VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(heading)
                .font(.title3)
                .fontWeight(.semibold)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Transfer

    private func performTransfer() async {
        guard let selectedMethod, let manager = cloudKitManager else { return }

        isTransferring = true
        defer { isTransferring = false }

        do {
            switch selectedMethod {
            case .cloudKit:
                do {
                    try await manager.uploadAudiobook(audiobook)
                } catch ChunkTransferError.alreadyUploaded {
                    // Finished by an earlier attempt; nothing left to send
                }
                iOSWatchConnectivityManager.shared.markCloudKitUploaded(
                    audiobookId: audiobook.id.uuidString)
                iOSWatchConnectivityManager.shared.announceCloudKitUpload(
                    audiobookId: audiobook.id)

            case .watchConnectivity:
                if !audiobook.isFileCached {
                    let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                    _ = try await audiobook.downloadAndCache(using: cacheManager)
                }
                try await iOSWatchConnectivityManager.shared.transferAudiobook(audiobook)

            case .iCloudDirect:
                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                _ = try await audiobook.downloadAndCache(using: cacheManager)

            case .alreadyUploaded:
                iOSWatchConnectivityManager.shared.announceCloudKitUpload(
                    audiobookId: audiobook.id)

            case .error(let reason):
                throw TransferError.noMethodAvailable(reason)
            }

            completedMethod = selectedMethod
        } catch ChunkTransferError.cancelled {
            // The user stopped it
        } catch {
            if presence.isVisible {
                transferError = error
                showError = true
            } else {
                // The sheet was closed mid-upload; the library reports it instead.
                iOSWatchConnectivityManager.shared.transferFailure = WatchTransferFailure(
                    audiobookId: audiobook.id,
                    title: audiobook.title,
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Method Presentation

    /// The other route, when it can carry this book.
    private func alternativeMethod(to method: SelectedMethod) -> SelectedMethod? {
        switch method {
        case .cloudKit:
            guard audiobook.isFileCached,
                audiobook.fileSize <= TransferMethodSelector.watchConnectivityLimit
            else { return nil }
            return .watchConnectivity(reason: "You chose to send it directly.")
        case .watchConnectivity:
            return .cloudKit(reason: "You chose to send it via iCloud.")
        default:
            return nil
        }
    }

    private func alternativeTitle(_ method: SelectedMethod) -> String {
        if case .cloudKit = method {
            return "Send via iCloud Instead"
        }
        return "Send Directly Instead"
    }

    private func startTitle(_ method: SelectedMethod) -> String? {
        switch method {
        case .cloudKit: "Upload to iCloud"
        case .watchConnectivity: "Send to Watch"
        case .iCloudDirect: "Download"
        case .alreadyUploaded: "Send to Watch"
        case .error: nil
        }
    }

    private func methodIcon(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit: "icloud.and.arrow.up"
        case .watchConnectivity: "applewatch"
        case .iCloudDirect: "icloud.and.arrow.down"
        case .alreadyUploaded: "checkmark.icloud"
        case .error: "exclamationmark.triangle"
        }
    }

    private func methodColor(_ method: SelectedMethod) -> Color {
        switch method {
        case .cloudKit, .alreadyUploaded: .blue
        case .watchConnectivity: .purple
        case .iCloudDirect: .green
        case .error: .red
        }
    }

    private func methodTitle(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit: "Send via iCloud"
        case .watchConnectivity: "Send Directly"
        case .iCloudDirect: "Download from iCloud Drive"
        case .alreadyUploaded: "Ready in iCloud"
        case .error: "Can't Send"
        }
    }

    /// What the route does, in the user's terms.
    private func methodSummary(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit:
            "Uploads the book to iCloud, and your Watch downloads it over Wi-Fi the next time Listen This is open there."
        case .watchConnectivity:
            "Sends the book straight from this iPhone to your Watch. Slower, but it keeps going in the background."
        case .iCloudDirect:
            "Downloads the book from iCloud Drive to this iPhone."
        case .alreadyUploaded:
            "The book is already in iCloud. Your Watch downloads it the next time Listen This is open there."
        case .error(let reason):
            reason
        }
    }
}

/// Whether the sheet is still on screen, readable from a transfer that
/// outlives it. A class so the task sees changes made after it started.
private final class SheetPresence {
    var isVisible = true
}
