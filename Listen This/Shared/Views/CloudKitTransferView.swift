//
//  CloudKitTransferView.swift
//  Listen This
//
//  SwiftUI view for CloudKit chunked transfers
//  Works on both iOS and watchOS
//

import SwiftUI
import SwiftData

struct CloudKitTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let audiobook: Audiobook
    
    @State private var transferManager: CloudKitChunkedTransferManager?
    @State private var cacheManager: AudiobookCacheManager?
    @State private var isProcessing = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var transferComplete = false
    
    #if os(iOS)
    private let mode: TransferMode = .upload
    #else
    private let mode: TransferMode = .download
    #endif
    
    enum TransferMode {
        case upload
        case download
    }
    
    var activeProgress: ChunkTransferProgress? {
        guard let manager = transferManager else { return nil }
        
        switch mode {
        case .upload:
            return manager.activeUploads[audiobook.id.uuidString]
        case .download:
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
                if transferComplete {
                    completionCard
                } else if let progress = activeProgress {
                    transferProgressCard(progress)
                } else {
                    transferActionCard
                }
            }
            .padding()
        }
        .navigationTitle(mode == .upload ? "Upload to Cloud" : "Download from Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(transferComplete ? "Done" : "Cancel") {
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
        VStack(spacing: 12) {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 3)
            }
            
            VStack(spacing: 6) {
                Text(audiobook.title)
                    .font(.headline)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "icloud.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("CloudKit Transfer")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text("Fast chunked transfer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Label("200MB chunks", systemImage: "square.stack.3d.up.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                
                #if os(watchOS)
                Label("WiFi required", systemImage: "wifi")
                    .font(.caption2)
                    .foregroundStyle(.green)
                #else
                Label("No proximity needed", systemImage: "applewatch.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                #endif
            }
        }
        .padding()
        #if os(iOS)
        .background(Color(.systemBackground))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.05), radius: 3)
    }
    
    // MARK: - Transfer Progress
    
    private func transferProgressCard(_ progress: ChunkTransferProgress) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    ProgressView()
                        .controlSize(.regular)
                    Text(progress.statusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                // Progress bar
                ProgressView(value: progress.progress) {
                    HStack {
                        Text("\(progress.progressPercentage)%")
                            .font(.caption2)
                        Spacer()
                        Text("\(progress.completedChunks) / \(progress.totalChunks) chunks")
                            .font(.caption2)
                    }
                }
                
                Text(progress.progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            Button(role: .destructive) {
                transferManager?.cancelTransfer(audiobookId: audiobook.id.uuidString)
                dismiss()
            } label: {
                Label("Cancel Transfer", systemImage: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }
    
    // MARK: - Transfer Action
    
    private var transferActionCard: some View {
        VStack(spacing: 12) {
            if mode == .upload {
                // iPhone: Upload to cloud
                VStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    
                    Text("Upload to CloudKit")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text("Upload this audiobook so it can be downloaded on your Apple Watch")
                        .font(.caption2)
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isProcessing)
                
            } else {
                // Watch: Download from cloud
                VStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    
                    Text("Download from CloudKit")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text("Download this audiobook to your Apple Watch")
                        .font(.caption2)
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
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isProcessing)
            }
            
            // Tips
            VStack(alignment: .leading, spacing: 6) {
                if mode == .upload {
                    Label("WiFi recommended", systemImage: "wifi")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Label("Uses CloudKit storage", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ensure uploaded first", systemImage: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Label("Best when charging", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .background(Color(.secondarySystemBackground))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
    
    // MARK: - Completion Card
    
    private var completionCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)
            
            Text(mode == .upload ? "Upload Complete" : "Download Complete")
                .font(.headline)
            
            Text(mode == .upload ? 
                "Audiobook is now available in CloudKit for download on your Apple Watch" :
                "Audiobook is now available for playback on your Apple Watch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    // MARK: - Actions
    
    private func uploadToCloud() async {
        guard let manager = transferManager else { return }
        
        isProcessing = true
        
        do {
            // Ensure file is cached first
            if !audiobook.isFileCached {
                guard let cacheManager = cacheManager,
                      let iCloudURL = audiobook.iCloudFileURL else {
                    throw ChunkTransferError.fileNotAvailable
                }
                // Download from iCloud to cache
                _ = try cacheManager.cacheAudiobook(audiobook, from: iCloudURL)
            }
            
            try await manager.uploadAudiobook(audiobook)
            
            await MainActor.run {
                isProcessing = false
                transferComplete = true
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
            let outputURL = try await manager.downloadAudiobook(audiobook)
            
            // Create cache entry
            let cacheEntry = CacheEntry(
                filePath: outputURL.path,
                fileSize: audiobook.fileSize
            )
            modelContext.insert(cacheEntry)
            audiobook.cacheEntry = cacheEntry
            
            try modelContext.save()
            
            await MainActor.run {
                isProcessing = false
                transferComplete = true
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

#Preview {
    NavigationStack {
        CloudKitTransferView(
            audiobook: Audiobook(
                title: "The Hobbit",
                author: "J.R.R. Tolkien",
                fileSize: 500_000_000
            )
        )
    }
    .modelContainer(for: [Audiobook.self])
}
