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
            
            // Send cached book list to iPhone when view appears
            connectivity.sendCachedAudiobookList()
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
                AudiobookRowWithActions(
                    audiobook: audiobook,
                    onTap: {
                        selectedAudiobook = audiobook
                        showingPlayer = true
                    }
                )
            }
        }
    }
    
    // MARK: - Actions
    
    private func removeDownload(for audiobook: Audiobook) {
        // Perform deletion with proper animation context
        withAnimation {
            // Remove the cache entry and file
            if let cacheEntry = audiobook.cacheEntry {
                // Delete file
                let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
                try? FileManager.default.removeItem(at: fileURL)
                
                // IMPORTANT: Clear the relationship BEFORE deleting the entry
                // This ensures SwiftData processes the changes in the correct order
                audiobook.cacheEntry = nil
                
                // Remove cache entry
                modelContext.delete(cacheEntry)
            }
            
            // Save changes within the animation block
            do {
                try modelContext.save()
            } catch {
                // If save fails, the UI state will be inconsistent
                // Force a save attempt without animation as fallback
                try? modelContext.save()
            }
        }
        
        // Update cached audiobook list sent to iPhone (after animation completes)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            connectivity.sendCachedAudiobookList()
        }
    }
}

// MARK: - Audiobook Row With Actions

struct AudiobookRowWithActions: View {
    let audiobook: Audiobook
    let onTap: () -> Void
    
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var connectivity
    
    @State private var showingDeleteConfirm = false
    @State private var showingTransferSheet = false
    
    // Capture audiobook ID at initialization
    private let audiobookId: UUID
    
    init(audiobook: Audiobook, onTap: @escaping () -> Void) {
        self.audiobook = audiobook
        self.onTap = onTap
        self.audiobookId = audiobook.id
    }
    
    var hasActiveTransfer: Bool {
        connectivity.activeTransfers[audiobookId.uuidString] != nil
    }
    
    var body: some View {
        AudiobookRow(audiobook: audiobook)
            .onTapGesture {
                onTap()
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Delete button
                if audiobook.isFileCached {
                    Button(role: .destructive) {
                        // Add small delay for watchOS gesture handling
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            showingDeleteConfirm = true
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                
                // Cancel transfer button
                if hasActiveTransfer {
                    Button(role: .destructive) {
                        connectivity.cancelTransfer(audiobookId: audiobook.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                // Download button - only show if not cached and not transferring
                if !audiobook.isFileCached && !hasActiveTransfer {
                    Button {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            showingTransferSheet = true
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.blue)
                }
            }
            .confirmationDialog(
                "Delete \"\(audiobook.title)\"?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete from Watch", role: .destructive) {
                    removeDownload(for: audiobook)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the downloaded file from your Apple Watch.")
            }
            .sheet(isPresented: $showingTransferSheet) {
                NavigationStack {
                    WatchTransferStatusView(audiobook: audiobook)
                }
            }
    }
    
    private func removeDownload(for audiobook: Audiobook) {
        // Perform deletion with proper animation context
        withAnimation {
            // Remove the cache entry and file
            if let cacheEntry = audiobook.cacheEntry {
                // Delete file
                let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
                try? FileManager.default.removeItem(at: fileURL)
                
                // IMPORTANT: Clear the relationship BEFORE deleting the entry
                // This ensures SwiftData processes the changes in the correct order
                audiobook.cacheEntry = nil
                
                // Remove cache entry
                modelContext.delete(cacheEntry)
            }
            
            // Save changes within the animation block
            do {
                try modelContext.save()
            } catch {
                // If save fails, the UI state will be inconsistent
                // Force a save attempt without animation as fallback
                try? modelContext.save()
            }
        }
        
        // Update cached audiobook list sent to iPhone (after animation completes)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            connectivity.sendCachedAudiobookList()
        }
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
