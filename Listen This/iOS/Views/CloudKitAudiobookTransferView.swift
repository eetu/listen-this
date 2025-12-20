//
//  CloudKitAudiobookTransferView.swift
//  Listen This
//
//  Transfer view using CloudKit chunked transfer
//  Much faster than WatchConnectivity for large files
//

import SwiftUI
import SwiftData

struct CloudKitAudiobookTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let audiobook: Audiobook
    let platform: Platform
    
    @State private var transferManager: CloudKitChunkedTransferManager?
    @State private var cacheManager: AudiobookCacheManager?
    @State private var isProcessing = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    enum Platform {
        case iPhone
        case watch
    }
    
    var activeProgress: ChunkTransferProgress? {
        guard let manager = transferManager else { return nil }
        
        switch platform {
        case .iPhone:
            return manager.activeUploads[audiobook.id.uuidString]
        case .watch:
            return manager.activeDownloads[audiobook.id.uuidString]
        }
    }
    
    var isTransferring: Bool {
        activeProgress != nil || isProcessing
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Audiobook info
                audiobookHeader
                
                // Transfer method info
                transferMethodCard
                
                // Transfer status or action
                if let progress = activeProgress {
                    transferProgressCard(progress)
                } else {
                    transferActionCard
                }
            }
            .padding()
        }
        .navigationTitle(platform == .iPhone ? "Upload to Cloud" : "Download from Cloud")
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
            transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
            cacheManager = AudiobookCacheManager(modelContext: modelContext)
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
    
    // MARK: - Transfer Method Card
    
    private var transferMethodCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "icloud.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("CloudKit Transfer")
                        .font(.headline)
                    
                    Text("Fast, reliable cloud transfer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Label("Works over WiFi", systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(.green)
                
                #if os(watchOS)
                Label("Download while charging", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                #endif
                
                Label("200MB chunks for reliability", systemImage: "square.stack.3d.up.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                
                Label("No device proximity required", systemImage: "applewatch.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
    
    // MARK: - Transfer Progress
    
    private func transferProgressCard(_ progress: ChunkTransferProgress) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack {
                    ProgressView()
                        .controlSize(.regular)
                    Text(progress.statusText)
                        .font(.headline)
                }
                
                // Progress bar
                ProgressView(value: progress.progress) {
                    HStack {
                        Text("\(progress.progressPercentage)%")
                            .font(.caption)
                        Spacer()
                        Text("\(progress.completedChunks) / \(progress.totalChunks) chunks")
                            .font(.caption)
                    }
                }
                
                Text(progress.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Button(role: .destructive) {
                transferManager?.cancelTransfer(audiobookId: audiobook.id.uuidString)
            } label: {
                Label("Cancel Transfer", systemImage: "xmark.circle.fill")
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
    
    // MARK: - Transfer Action
    
    private var transferActionCard: some View {
        VStack(spacing: 16) {
            if platform == .iPhone {
                // iPhone: Upload to cloud
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    
                    Text("Upload to CloudKit")
                        .font(.headline)
                    
                    Text("Upload this audiobook to iCloud so it can be downloaded on your Apple Watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                Button {
                    Task {
                        await uploadToCloud()
                    }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Image(systemName: "icloud.and.arrow.up.fill")
                        Text(isProcessing ? "Uploading..." : "Upload to Cloud")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isProcessing ? Color.gray.opacity(0.6) : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProcessing)
                
            } else {
                // Watch: Download from cloud
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    
                    Text("Download from CloudKit")
                        .font(.headline)
                    
                    Text("Download this audiobook from iCloud to your Apple Watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                
                Button {
                    Task {
                        await downloadFromCloud()
                    }
                } label: {
                    HStack {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Image(systemName: "icloud.and.arrow.down.fill")
                        Text(isProcessing ? "Downloading..." : "Download from Cloud")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isProcessing ? Color.gray.opacity(0.6) : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProcessing)
            }
            
            // Tips
            VStack(alignment: .leading, spacing: 8) {
                if platform == .iPhone {
                    Label("WiFi recommended for large files", systemImage: "wifi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Label("Uses CloudKit storage quota", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ensure iPhone has uploaded first", systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Label("Best when Watch is charging", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    // MARK: - Actions
    
    private func uploadToCloud() async {
        guard let manager = transferManager else { return }
        
        isProcessing = true
        
        do {
            try await manager.uploadAudiobook(audiobook)
            
            await MainActor.run {
                isProcessing = false
            }
            
        } catch {
            await MainActor.run {
                errorMessage = "Upload failed: \(error.localizedDescription)"
                showingError = true
                isProcessing = false
            }
        }
    }
    
    private func downloadFromCloud() async {
        guard let manager = transferManager else { return }
        
        isProcessing = true
        
        do {
            _ = try await manager.downloadAudiobook(audiobook)
            
            await MainActor.run {
                isProcessing = false
                // File is now at audiobook.expectedCachePath
            }
            
        } catch {
            await MainActor.run {
                errorMessage = "Download failed: \(error.localizedDescription)"
                showingError = true
                isProcessing = false
            }
        }
    }
}

#if os(iOS)
#Preview {
    NavigationStack {
        CloudKitAudiobookTransferView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 500_000_000
            ),
            platform: .iPhone
        )
    }
    .modelContainer(for: [Audiobook.self])
}
#endif
