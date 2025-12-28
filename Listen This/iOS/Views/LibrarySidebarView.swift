//
//  LibrarySidebarView.swift
//  listen this
//
//  Created on 27.12.2025.
//

import SwiftUI
import SwiftData

struct LibrarySidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) private var audiobooks: [Audiobook]
    @State private var connectivity: iOSWatchConnectivityManager?

    @Binding var selectedAudiobook: Audiobook?

    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var showingSettings = false

    // Sheet state - storing IDs instead of model objects
    @State private var deleteAudiobookId: UUID?
    @State private var transferAudiobookId: UUID?

    var filteredAudiobooks: [Audiobook] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText) ||
            book.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if let connectivity {
                sidebarContent(connectivity: connectivity)
            } else {
                ProgressView("Loading...")
            }
        }
        .task {
            if connectivity == nil {
                let manager = iOSWatchConnectivityManager.shared
                manager.configure(modelContext: modelContext)
                connectivity = manager
            }
        }
    }

    @ViewBuilder
    private func sidebarContent(connectivity: iOSWatchConnectivityManager) -> some View {
        List(filteredAudiobooks, selection: $selectedAudiobook) { book in
            LibrarySidebarRow(audiobook: book, connectivity: connectivity)
                .tag(book)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Delete action
                    if book.isFileCached || book.iCloudRelativePath != nil {
                        Button(role: .destructive) {
                            deleteAudiobookId = book.id
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Transfer to Watch
                    if connectivity.isPaired && connectivity.isWatchAppInstalled {
                        Button {
                            transferAudiobookId = book.id
                        } label: {
                            Label("Transfer", systemImage: "applewatch")
                        }
                        .tint(.blue)
                    }
                }
                .contextMenu {
                    contextMenuItems(for: book, connectivity: connectivity)
                }
        }
        .searchable(text: $searchText, prompt: "Search audiobooks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAddBook = true
                } label: {
                    Label("Add Book", systemImage: "plus")
                }

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $showingAddBook) {
            ImportView()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: .init(
            get: { deleteAudiobookId != nil },
            set: { if !$0 { deleteAudiobookId = nil } }
        )) {
            if let id = deleteAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                DeleteOptionsSheet(
                    audiobook: audiobook,
                    connectivity: connectivity,
                    modelContext: modelContext,
                    onDismiss: {
                        deleteAudiobookId = nil
                    }
                )
            }
        }
        .sheet(isPresented: .init(
            get: { transferAudiobookId != nil },
            set: { if !$0 { transferAudiobookId = nil } }
        )) {
            if let id = transferAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                NavigationStack {
                    AutoTransferView(audiobook: audiobook)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(for audiobook: Audiobook, connectivity: iOSWatchConnectivityManager) -> some View {
        // Send to Watch
        if connectivity.isPaired && connectivity.isWatchAppInstalled {
            Button {
                transferAudiobookId = audiobook.id
            } label: {
                Label("Send to Watch", systemImage: "applewatch")
            }
        }

        // Delete (only show if file exists)
        if audiobook.isFileCached || audiobook.iCloudRelativePath != nil {
            Button(role: .destructive) {
                deleteAudiobookId = audiobook.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Sidebar Row Component

struct LibrarySidebarRow: View {
    let audiobook: Audiobook
    let connectivity: iOSWatchConnectivityManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork thumbnail
            if let artworkData = audiobook.artworkData,
               let image = UIImage(data: artworkData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "book.fill")
                            .foregroundStyle(.secondary)
                    }
            }
            
            // Book info
            VStack(alignment: .leading, spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                // Progress indicator
                if let session = audiobook.playbackSession,
                   session.currentPosition > 0 {
                    ProgressView(value: session.currentPosition, total: audiobook.duration)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    @Previewable @State var selectedAudiobook: Audiobook?
    NavigationStack {
        LibrarySidebarView(selectedAudiobook: $selectedAudiobook)
            .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
    }
}
