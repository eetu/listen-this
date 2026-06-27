//
//  WatchConnectivityTransferView.swift
//  Listen This
//
//  Direct device-to-device transfer to Apple Watch via WatchConnectivity
//  Uses Bluetooth/WiFi Direct for file transfer (alternative to CloudKit)
//

import OSLog
import SwiftData
import SwiftUI
import UIKit

struct WatchConnectivityTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(iOSWatchConnectivityManager.self) private var connectivity

    let audiobook: Audiobook
    
    private let settingsManager = SettingsManager.shared

    @State private var cacheManager: AudiobookCacheManager?
    @State private var isTransferring = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isCharging = false

    var activeTransfer: WatchTransferProgress? {
        connectivity.activeTransfers[audiobook.id.uuidString]
    }

    var hasActiveTransfer: Bool {
        activeTransfer != nil
    }
    
    /// Whether transfer is blocked due to charging-only setting
    var isBlockedByChargingSetting: Bool {
        settingsManager.transferToWatchWhileChargingOnly && !isCharging
    }

    var buttonText: String {
        if hasActiveTransfer {
            return "Transferring..."
        } else if isTransferring {
            if audiobook.isFileCached {
                return "Transferring..."
            } else {
                return "Downloading..."
            }
        } else {
            if audiobook.isFileCached {
                return "Transfer to Watch"
            } else {
                return "Download & Transfer"
            }
        }
    }

    var buttonBackground: Color {
        (isTransferring || hasActiveTransfer) ? Color.gray.opacity(0.6) : Color.blue
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Audiobook info
                audiobookHeader

                // Watch status
                watchStatusCard

                // Transfer status or action
                if let transfer = activeTransfer {
                    transferProgressCard(transfer)
                } else {
                    transferActionCard
                }
            }
            .padding()
        }
        .navigationTitle("Transfer to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .alert("Transfer Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            cacheManager = AudiobookCacheManager(modelContext: modelContext)
            connectivity.configure(modelContext: modelContext)
            
            // Enable battery monitoring
            UIDevice.current.isBatteryMonitoringEnabled = true
            updateChargingState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            updateChargingState()
        }
    }

    // MARK: - Audiobook Header

    private var audiobookHeader: some View {
        VStack(spacing: 16) {
            if let artworkData = audiobook.artworkData,
                let uiImage = UIImage(data: artworkData)
            {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 5)
            }

            VStack(spacing: 8) {
                Text(audiobook.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if audiobook.fileSize > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: audiobook.fileSize, countStyle: .file))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Watch Status Card

    private var watchStatusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: connectivity.isPaired ? "applewatch" : "applewatch.slash")
                    .foregroundStyle(connectivity.isPaired ? .green : .secondary)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Watch")
                        .font(.headline)

                    if connectivity.isPaired {
                        if connectivity.isReachable {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Not connected", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Not paired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 5)
        }
    }

    // MARK: - Transfer Progress

    /// A queued transfer hasn't started moving bytes and the Watch is out of
    /// range — WatchConnectivity will deliver it once the Watch is reachable.
    private func isQueued(_ transfer: WatchTransferProgress) -> Bool {
        transfer.isActive && transfer.bytesTransferred == 0 && !connectivity.isReachable
    }

    /// Formats elapsed time as m:ss or h:mm:ss for the indeterminate indicator.
    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func transferProgressCard(_ transfer: WatchTransferProgress) -> some View {
        VStack(spacing: 16) {
            if isQueued(transfer) {
                queuedTransferView
                cancelTransferButton
            } else if transfer.isActive {
                // Active transfer. WatchConnectivity doesn't report byte-level
                // progress on the sender, so show an honest indeterminate
                // indicator (with size + elapsed time) rather than a frozen 0%.
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.top, 4)

                    VStack(spacing: 8) {
                        Text("Transferring to Watch")
                            .font(.headline)

                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: transfer.totalBytes, countStyle: .file)
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                        TimelineView(.periodic(from: transfer.startTime, by: 1)) { context in
                            Text("Elapsed \(elapsedString(from: transfer.startTime, to: context.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Text(
                            "Progress isn't reported during direct transfer. Keep your Apple Watch nearby — large books can take several minutes."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                cancelTransferButton
            } else {
                // Transfer complete
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)

                    Text("Transfer Complete")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("The audiobook is now available on your Apple Watch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    // Show final transfer stats
                    HStack(spacing: 16) {
                        VStack(spacing: 4) {
                            Text(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))
                                .font(.headline)
                                .monospacedDigit()
                            Text("Total Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        if !transfer.averageSpeedText.isEmpty {
                            Divider()
                                .frame(height: 30)

                            VStack(spacing: 4) {
                                Text(transfer.averageSpeedText)
                                    .font(.headline)
                                    .monospacedDigit()
                                Text("Avg Speed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var queuedTransferView: some View {
        VStack(spacing: 12) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Waiting for Apple Watch")
                .font(.headline)

            Text("The transfer is queued and will start automatically when your Watch is in range.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cancelTransferButton: some View {
        Button(role: .destructive) {
            connectivity.cancelTransfer(for: audiobook.id.uuidString)
        } label: {
            Label("Cancel Transfer", systemImage: "xmark.circle.fill")
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
        .tint(.red)
    }

    // MARK: - Transfer Action

    private var transferActionCard: some View {
        VStack(spacing: 16) {
            // Charging requirement warning
            if isBlockedByChargingSetting {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Charging Required")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Connect your iPhone to power to start the transfer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            if audiobook.isFileCached {
                Button {
                    Task {
                        await transferAudiobook()
                    }
                } label: {
                    Label(
                        buttonText,
                        systemImage: hasActiveTransfer
                            ? "arrow.clockwise" : "applewatch.and.arrow.forward"
                    )
                    .font(.headline)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isTransferring || hasActiveTransfer || !connectivity.isPaired
                        || !connectivity.isWatchAppInstalled || isBlockedByChargingSetting)

            } else {
                Button {
                    Task {
                        await downloadAndTransfer()
                    }
                } label: {
                    Label(
                        buttonText,
                        systemImage: hasActiveTransfer
                            ? "arrow.clockwise" : "arrow.down.circle.fill"
                    )
                    .font(.headline)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
                .disabled(
                    isTransferring || hasActiveTransfer || !connectivity.isPaired
                        || !connectivity.isWatchAppInstalled || isBlockedByChargingSetting)
            }

            // Tips
            VStack(alignment: .leading, spacing: 8) {
                Label("Make sure your Apple Watch is nearby", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("Large files may take several minutes", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    private func transferAudiobook() async {
        guard cacheManager != nil else { return }

        // Prevent duplicate transfers
        if hasActiveTransfer {
            AppLogger.watchConnectivity.warning(
                "Transfer already in progress for: \(audiobook.title)")
            return
        }

        isTransferring = true

        do {
            // Transfer to watch
            try await connectivity.transferAudiobook(audiobook)

            await MainActor.run {
                isTransferring = false
            }

        } catch let error as WatchTransferError {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                isTransferring = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to transfer: \(error.localizedDescription)"
                showingError = true
                isTransferring = false
            }
        }
    }

    private func downloadAndTransfer() async {
        guard let cacheManager = cacheManager else { return }

        // Prevent duplicate transfers
        if hasActiveTransfer {
            AppLogger.watchConnectivity.warning(
                "Transfer already in progress for: \(audiobook.title)")
            return
        }

        isTransferring = true

        do {
            // First download from iCloud
            _ = try await audiobook.downloadAndCache(using: cacheManager)

            // Then transfer to watch
            try await connectivity.transferAudiobook(audiobook)

            await MainActor.run {
                isTransferring = false
            }

        } catch let error as WatchTransferError {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showingError = true
                isTransferring = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to download and transfer: \(error.localizedDescription)"
                showingError = true
                isTransferring = false
            }
        }
    }
    
    // MARK: - Battery Monitoring
    
    private func updateChargingState() {
        let batteryState = UIDevice.current.batteryState
        isCharging = batteryState == .charging || batteryState == .full
    }
}

#Preview {
    NavigationStack {
        WatchConnectivityTransferView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 500_000_000
            )
        )
    }
    .modelContainer(for: [Audiobook.self])
    .environment(iOSWatchConnectivityManager.shared)
}
