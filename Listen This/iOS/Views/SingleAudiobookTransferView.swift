//
//  SingleAudiobookTransferView.swift
//  Listen This
//
//  Quick transfer view for a single audiobook to Apple Watch
//

import SwiftUI
import SwiftData

#if os(iOS)

struct SingleAudiobookTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(iOSWatchConnectivityManager.self) private var connectivity
    
    let audiobook: Audiobook
    
    @State private var cacheManager: AudiobookCacheManager?
    @State private var isTransferring = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var activeTransfer: WatchTransferProgress? {
        connectivity.activeTransfers[audiobook.id.uuidString]
    }
    
    var hasActiveTransfer: Bool {
        activeTransfer != nil
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
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            cacheManager = AudiobookCacheManager(modelContext: modelContext)
            connectivity.configure(modelContext: modelContext)
            
            // Check if there's already an active transfer for this audiobook
            if hasActiveTransfer {
                print("ℹ️ [iOS Transfer] Active transfer detected for: \(audiobook.title)")
            }
        }
    }
    
    // MARK: - Audiobook Header
    
    private var audiobookHeader: some View {
        VStack(spacing: 16) {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
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
                        Text(ByteCountFormatter.string(fromByteCount: audiobook.fileSize, countStyle: .file))
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
    
    private func transferProgressCard(_ transfer: WatchTransferProgress) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack {
                    if transfer.isActive {
                        ProgressView()
                            .controlSize(.regular)
                    }
                    Text(transfer.isActive ? "Transferring..." : "Transfer Complete")
                        .font(.headline)
                }
                
                if transfer.isActive {
                    Text("Keep your Apple Watch nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(transfer.isActive ? Color.blue.opacity(0.1) : Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            if transfer.isActive {
                Button(role: .destructive) {
                    connectivity.cancelTransfer(for: audiobook.id.uuidString)
                } label: {
                    Label("Cancel Transfer", systemImage: "xmark.circle.fill")
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .tint(.red)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    
                    Text("Transfer Complete")
                        .font(.headline)
                    
                    Text("The audiobook is now available on your Apple Watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }
    
    // MARK: - Transfer Action
    
    private var transferActionCard: some View {
        VStack(spacing: 16) {
            if audiobook.isFileCached {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                    
                    Text("Ready to Transfer")
                        .font(.headline)
                    
                    Text("This audiobook is downloaded and ready to transfer to your Apple Watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                Button {
                    Task {
                        await transferAudiobook()
                    }
                } label: {
                    HStack {
                        if isTransferring || hasActiveTransfer {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Image(systemName: hasActiveTransfer ? "arrow.clockwise" : "arrow.down.circle.fill")
                        Text(buttonText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(buttonBackground)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isTransferring || hasActiveTransfer || !connectivity.isPaired || !connectivity.isWatchAppInstalled)
                
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    
                    Text("Download Required")
                        .font(.headline)
                    
                    Text("This audiobook will be downloaded from iCloud and then transferred to your Apple Watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                Button {
                    Task {
                        await downloadAndTransfer()
                    }
                } label: {
                    HStack {
                        if isTransferring || hasActiveTransfer {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Image(systemName: hasActiveTransfer ? "arrow.clockwise" : "arrow.down.circle.fill")
                        Text(buttonText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(buttonBackground)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isTransferring || hasActiveTransfer || !connectivity.isPaired || !connectivity.isWatchAppInstalled)
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
        guard let cacheManager = cacheManager else { return }
        
        // Prevent duplicate transfers
        if hasActiveTransfer {
            print("⚠️ [iOS Transfer] Transfer already in progress for: \(audiobook.title)")
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
            print("⚠️ [iOS Transfer] Transfer already in progress for: \(audiobook.title)")
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
}

#Preview {
    NavigationStack {
        SingleAudiobookTransferView(
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

#endif
