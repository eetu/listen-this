//
//  WatchLibraryView.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity

struct WatchLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var connectivity
    
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse)
    private var audiobooks: [Audiobook]
    
    @State private var selectedAudiobook: Audiobook?
    @State private var showingPlayer = false

    var body: some View {
        NavigationStack {
            Group {
                if audiobooks.isEmpty {
                    emptyStateView
                } else {
                    audiobookList
                }
            }
            .navigationTitle("Library")
            .navigationDestination(isPresented: $showingPlayer) {
                if let audiobook = selectedAudiobook {
                    WatchPlayerView(audiobook: audiobook)
                }
            }
        }
        .onAppear {
            connectivity.configure(modelContext: modelContext)
            
            // Log active transfers
            print("⌚ [Watch Library] View appeared")
            print("⌚ [Watch Library] Active transfers: \(connectivity.activeTransfers.count)")
            for (audiobookId, _) in connectivity.activeTransfers {
                print("   - \(audiobookId): transferring")
            }
            
            // Check if WCSession has content pending
            if WCSession.default.hasContentPending {
                print("⌚ [Watch Library] WCSession reports content pending")
            } else {
                print("⌚ [Watch Library] No content pending in WCSession")
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("No Books")
                .font(.headline)
            
            Text("Add books on your iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if connectivity.isReachable {
                Button {
                    connectivity.requestLibrarySync()
                } label: {
                    Label("Sync with iPhone", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            } else {
                Label("iPhone not connected", systemImage: "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding()
    }
    
    // MARK: - Audiobook List
    
    private var audiobookList: some View {
        List {
            ForEach(audiobooks) { audiobook in
                AudiobookRow(audiobook: audiobook)
                    .onTapGesture {
                        selectedAudiobook = audiobook
                        showingPlayer = true
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if audiobook.isFileCached {
                            Button(role: .destructive) {
                                removeDownload(for: audiobook)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
            }
        }
    }
    
    // MARK: - Actions
    
    private func removeDownload(for audiobook: Audiobook) {
        // Remove the cache entry and file
        if let cacheEntry = audiobook.cacheEntry {
            // Delete file
            let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            
            // Remove cache entry
            modelContext.delete(cacheEntry)
        }
        
        // Clear audiobook cache reference
        audiobook.cacheEntry = nil
        // DON'T clear localFilename - it's needed for future transfers!
        // audiobook.localFilename = nil
        
        // Save changes
        try? modelContext.save()
        
        print("🗑️ [Watch Library] Removed download (swipe action): \(audiobook.title)")
        print("   Kept localFilename: \(audiobook.localFilename ?? "nil")")
    }
}

// MARK: - Audiobook Row

struct AudiobookRow: View {
    let audiobook: Audiobook
    @Environment(WatchConnectivityManager.self) private var connectivity
    
    @State private var showingTransferSheet = false
    
    var hasActiveTransfer: Bool {
        connectivity.activeTransfers[audiobook.id.uuidString] != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                // Artwork thumbnail
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
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
                        .lineLimit(2)
                    
                    Text(audiobook.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if hasActiveTransfer {
                print("⌚ [Watch Row] Active transfer for '\(audiobook.title)'")
            }
        }
        .sheet(isPresented: $showingTransferSheet) {
            NavigationStack {
                WatchTransferStatusView(audiobook: audiobook)
            }
        }
    }
    
    @ViewBuilder
    private var cacheStatusBadge: some View {
        HStack(spacing: 4) {
            if audiobook.isFileCached {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if connectivity.activeTransfers[audiobook.id.uuidString] != nil {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            } else {
                Button {
                    showingTransferSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                        Text("Download")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    WatchLibraryView()
        .modelContainer(for: [Audiobook.self])
        .environment(WatchConnectivityManager.shared)
}
