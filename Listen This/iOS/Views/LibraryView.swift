//
//  LibraryView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) private var audiobooks: [Audiobook]

    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var showingSettings = false
    
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
        NavigationStack {
            Group {
                if audiobooks.isEmpty {
                    emptyStateView
                } else {
                    libraryGrid
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search audiobooks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddBook = true
                    } label: {
                        Label("Add Book", systemImage: "plus")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
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
            .onAppear {
                print("📱 [iPhone] Library loaded with \(audiobooks.count) books")
                for book in audiobooks {
                    print("📚 [iPhone] Book: \(book.title) by \(book.author)")
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Audiobooks", systemImage: "book.closed")
        } description: {
            Text("Add audiobooks from iCloud Drive, Jellyfin, or AudiobookShelf")
        } actions: {
            Button("Add Audiobook") {
                showingAddBook = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Library Grid
    
    private var libraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160), spacing: 16)
            ], spacing: 16) {
                ForEach(filteredAudiobooks) { book in
                    AudiobookCardWithMenu(audiobook: book)
                }
            }
            .padding()
            .animation(.default, value: filteredAudiobooks.count)
        }
        .navigationDestination(for: Audiobook.self) { book in
            PlayerView(audiobook: book)
        }
    }
}

// MARK: - Audiobook Card

// Wrapper view that manages the card, navigation, and context menu together
struct AudiobookCardWithMenu: View {
    let audiobook: Audiobook
    @Environment(\.modelContext) private var modelContext
    
    @State private var showDeleteOptions = false
    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var showWatchTransfer = false
    
    #if os(iOS)
    @Environment(iOSWatchConnectivityManager.self) private var connectivity
    #endif
    
    var body: some View {
        NavigationLink(value: audiobook) {
            AudiobookCard(audiobook: audiobook)
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuContent
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = ""
            }
        } message: {
            Text(deleteErrorMessage)
        }
        #if os(iOS)
        .sheet(isPresented: $showWatchTransfer) {
            NavigationStack {
                SingleAudiobookTransferView(audiobook: audiobook)
                    .environment(connectivity)
            }
        }
        .sheet(isPresented: $showDeleteOptions) {
            deleteOptionsSheet
        }
        #endif
    }
    
    #if os(iOS)
    @ViewBuilder
    private var deleteOptionsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        showDeleteOptions = false
                        // Give the sheet time to dismiss before deleting
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            await deleteAudiobook(deleteFromiCloud: false)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Delete from iPhone Only")
                                .font(.headline)
                            Text("Removes cached file from this device. File remains in iCloud.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button(role: .destructive) {
                        showDeleteOptions = false
                        // Give the sheet time to dismiss before deleting
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            await deleteAudiobook(deleteFromiCloud: true)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Delete Everywhere")
                                .font(.headline)
                            Text("Removes file from iCloud Drive and all devices. Metadata syncs via CloudKit.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Delete \"\(audiobook.title)\"?")
                }
                
                Section {
                    Button("Cancel", role: .cancel) {
                        showDeleteOptions = false
                    }
                }
            }
            .navigationTitle("Delete Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
        }
    }
    #endif
    
    @ViewBuilder
    private var contextMenuContent: some View {
        // Info label showing cached status
        if audiobook.isFileCached {
            Label("Downloaded on iPhone", systemImage: "checkmark.icloud")
        } else {
            Label("Available in iCloud", systemImage: "icloud")
        }

        Divider()

        // Cache management
        if audiobook.isFileCached {
            Button(role: .destructive) {
                removeCacheFromiPhone()
            } label: {
                Label("Remove from iPhone", systemImage: "trash")
            }
        }

        #if os(iOS)
        // Transfer to Watch button or cancel button
        if connectivity.isPaired && connectivity.isWatchAppInstalled {
            if connectivity.activeTransfers[audiobook.id.uuidString] != nil {
                // Show cancel option when transfer is active
                Button(role: .destructive) {
                    connectivity.cancelTransfer(for: audiobook.id.uuidString)
                } label: {
                    Label("Cancel Transfer", systemImage: "xmark.circle")
                }
            } else {
                // Show transfer option when no active transfer
                Button {
                    showWatchTransfer = true
                } label: {
                    Label("Transfer to Watch", systemImage: "applewatch")
                }
            }
        }

        Divider()
        #endif

        // Delete button - opens sheet with options
        Button(role: .destructive) {
            print("🔘 [UI] Delete button tapped in context menu")
            showDeleteOptions = true
        } label: {
            if isDeleting {
                Label("Deleting...", systemImage: "trash")
            } else {
                Label("Delete Audiobook", systemImage: "trash")
            }
        }
        .disabled(isDeleting)
    }
    
    private func removeCacheFromiPhone() {
        Task {
            do {
                print("🗑️ [UI] Removing cached file from iPhone...")
                print("   Title: \(audiobook.title)")

                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                try cacheManager.deleteCachedFile(for: audiobook)

                await MainActor.run {
                    print("✅ [UI] Cache removed successfully")
                }
            } catch {
                await MainActor.run {
                    print("❌ [UI] Failed to remove cache: \(error)")
                    deleteErrorMessage = "Failed to remove cached file: \(error.localizedDescription)"
                    showDeleteError = true
                }
            }
        }
    }

    @MainActor
    private func deleteAudiobook(deleteFromiCloud: Bool) async {
        print("🔘 [UI] deleteAudiobook function called")
        print("   Title: \(audiobook.title)")
        print("   Delete from iCloud: \(deleteFromiCloud)")
        
        isDeleting = true
        
        do {
            print("🗑️ [UI] Starting delete operation...")
            
            let service = AudiobookLibraryService(modelContext: modelContext)
            try await service.deleteAudiobook(
                audiobook,
                deleteFromiCloud: deleteFromiCloud
            )
            
            print("✅ [UI] Audiobook deleted successfully")
            isDeleting = false
            
        } catch {
            print("❌ [UI] Delete failed: \(error)")
            print("   Error type: \(type(of: error))")
            print("   Error description: \(error.localizedDescription)")
            
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
            isDeleting = false
        }
    }
}

// MARK: - Audiobook Card (Presentation Only)

struct AudiobookCard: View {
    let audiobook: Audiobook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork
            Group {
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.tertiary)

                        Image(systemName: "book.closed")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)

            // Title
            Text(audiobook.title)
                .font(.headline)
                .lineLimit(2)

            // Author
            Text(audiobook.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Progress indicator
            if let session = audiobook.playbackSession {
                ProgressView(value: session.progressPercentage, total: 100)
                    .tint(.accentColor)
            }
        }
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
}
