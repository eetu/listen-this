//
//  WatchTransferView.swift
//  Listen This
//
//  View for managing audiobook transfers to Apple Watch
//

import SwiftUI
import SwiftData

#if os(iOS)

struct WatchTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(iOSWatchConnectivityManager.self) private var connectivity
    
    @Query private var audiobooks: [Audiobook]
    
    @State private var cacheManager: AudiobookCacheManager?
    @State private var selectedAudiobook: Audiobook?
    @State private var showingError = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationStack {
            List {
                // Watch Status Section
                watchStatusSection
                
                // Active Transfers Section
                if !connectivity.activeTransfers.isEmpty {
                    activeTransfersSection
                }
                
                // Available Audiobooks Section
                availableAudiobooksSection
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
            }
        }
    }
    
    // MARK: - Watch Status
    
    private var watchStatusSection: some View {
        Section {
            HStack {
                Image(systemName: connectivity.isPaired ? "applewatch" : "applewatch.slash")
                    .foregroundStyle(connectivity.isPaired ? .green : .secondary)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Watch")
                        .font(.headline)
                    
                    if connectivity.isPaired {
                        if connectivity.isWatchAppInstalled {
                            if connectivity.isReachable {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("Paired (Not connected)", systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Label("App not installed", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Not paired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.vertical, 8)
        } header: {
            Text("Device Status")
        }
    }
    
    // MARK: - Active Transfers
    
    private var activeTransfersSection: some View {
        Section {
            ForEach(Array(connectivity.activeTransfers.values), id: \.audiobookId) { transfer in
                HStack(spacing: 12) {
                    // Transfer status indicator
                    if transfer.isActive {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transfer.audiobookTitle)
                            .font(.headline)
                        
                        Text(transfer.isActive ? "Transferring..." : "Complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Cancel button (only when active)
                    if transfer.isActive {
                        Button {
                            connectivity.cancelTransfer(for: transfer.audiobookId)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Active Transfers")
        }
    }
    
    // MARK: - Available Audiobooks
    
    private var availableAudiobooksSection: some View {
        Section {
            ForEach(audiobooks.filter { !$0.isArchived }) { audiobook in
                AudiobookTransferRow(
                    audiobook: audiobook,
                    isTransferring: connectivity.activeTransfers[audiobook.id.uuidString] != nil,
                    onTransfer: {
                        Task {
                            await transferAudiobook(audiobook)
                        }
                    }
                )
            }
        } header: {
            Text("Your Audiobooks")
        } footer: {
            Text("Transfer audiobooks to your Apple Watch for offline listening. Files are automatically downloaded from iCloud if needed.")
                .font(.caption)
        }
    }
    
    // MARK: - Transfer Action
    
    private func transferAudiobook(_ audiobook: Audiobook) async {
        guard let cacheManager = cacheManager else { return }
        
        do {
            // First, ensure the file is cached on iPhone
            if !audiobook.isFileCached {
                print("📥 [WatchTransfer] Downloading from iCloud first...")
                _ = try await audiobook.downloadAndCache(using: cacheManager)
            }
            
            // Then transfer to Watch
            print("📤 [WatchTransfer] Transferring to Watch...")
            try await connectivity.transferAudiobook(audiobook)
            
        } catch let error as WatchTransferError {
            errorMessage = error.localizedDescription
            showingError = true
        } catch {
            errorMessage = "Failed to transfer audiobook: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - Audiobook Transfer Row

struct AudiobookTransferRow: View {
    let audiobook: Audiobook
    let isTransferring: Bool
    let onTransfer: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "book.fill")
                            .foregroundStyle(.secondary)
                    }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Cache status
                    if audiobook.isFileCached {
                        Label("Cached", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("In iCloud", systemImage: "icloud")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    
                    // File size
                    if audiobook.fileSize > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: audiobook.fileSize, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Transfer button
            if isTransferring {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Button {
                    onTransfer()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    WatchTransferView()
        .modelContainer(for: [Audiobook.self])
        .environment(iOSWatchConnectivityManager.shared)
}

#endif
