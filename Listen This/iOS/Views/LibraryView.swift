//
//  LibraryView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity

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
                ToolbarItemGroup(placement: .topBarTrailing) {
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
    
    // MARK: - Library List
    
    private var libraryGrid: some View {
        List {
            ForEach(filteredAudiobooks) { book in
                AudiobookCardWithMenu(audiobook: book)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .id(book.id) // Stabilize list item identity
            }
        }
        .listStyle(.plain)
        .animation(.default, value: filteredAudiobooks.count)
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
    @State private var pendingDeleteOption: Bool?
    
    @Environment(iOSWatchConnectivityManager.self) private var connectivity
    
    // CRITICAL: Capture audiobook ID at initialization to prevent SwiftData identity issues
    private let audiobookId: UUID
    
    // Cache the transfer states to prevent unnecessary re-renders
    @State private var hasActiveTransfer = false
    @State private var isOnWatch = false
    
    init(audiobook: Audiobook) {
        self.audiobook = audiobook
        self.audiobookId = audiobook.id // Capture ID immediately
    }
    
    var body: some View {
        NavigationLink(value: audiobook) {
            AudiobookCard(audiobook: audiobook)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Delete button - opens sheet with options
            Button(role: .destructive) {
                // Add a small delay to allow swipe action to complete before showing sheet
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    showDeleteOptions = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            
            // Transfer to Watch button or cancel button
            if connectivity.isPaired && connectivity.isWatchAppInstalled {
                if hasActiveTransfer {
                    // Show cancel option when transfer is active
                    Button(role: .destructive) {
                        connectivity.cancelTransfer(for: audiobookId.uuidString)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                } else if isOnWatch {
                    // File is cached on Watch, show option to delete from Watch
                    Button {
                        removeFromAppleWatch()
                    } label: {
                        Label("Remove", systemImage: "applewatch.slash")
                    }
                    .tint(.orange)
                } else if !audiobook.isFileCached {
                    // Only show transfer option if file is not already cached locally
                    // (If it's not on iPhone, it can't be on Watch either)
                    Button {
                        showWatchTransfer = true
                    } label: {
                        Label("Transfer", systemImage: "applewatch")
                    }
                    .tint(.purple)
                } else {
                    // File is cached on iPhone and NOT on Watch, show transfer option
                    Button {
                        showWatchTransfer = true
                    } label: {
                        Label("Transfer", systemImage: "applewatch")
                    }
                    .tint(.purple)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Cache management on leading edge
            if audiobook.isFileCached {
                Button {
                    removeCacheFromiPhone()
                } label: {
                    Label("Remove from iPhone", systemImage: "iphone.slash")
                }
                .tint(.orange)
            }
            
            // Delete from iCloud (more destructive, on leading edge)
            if audiobook.iCloudRelativePath != nil {
                Button(role: .destructive) {
                    Task {
                        await deleteAudiobook(audiobookId: audiobookId, deleteFromiCloud: true)
                    }
                } label: {
                    Label("Delete from iCloud", systemImage: "icloud.slash")
                }
                .tint(.red)
            }
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = ""
            }
        } message: {
            Text(deleteErrorMessage)
        }
        .sheet(isPresented: $showWatchTransfer) {
            NavigationStack {
                SingleAudiobookTransferView(audiobook: audiobook)
                    .environment(connectivity)
            }
        }
        .sheet(isPresented: $showDeleteOptions) {
            deleteOptionsSheet
        }
        // CRITICAL: Use .onChange to detect when sheet is dismissed
        // This ensures deletion happens AFTER sheet is fully dismissed
        .onChange(of: showDeleteOptions) { oldValue, newValue in
            if oldValue == true && newValue == false {
                // Sheet just dismissed, check if we should delete
                if let deleteOption = pendingDeleteOption {
                    Task {
                        // Wait for sheet dismissal animation to complete
                        try? await Task.sleep(for: .milliseconds(500))
                        await deleteAudiobook(audiobookId: audiobookId, deleteFromiCloud: deleteOption)
                        pendingDeleteOption = nil
                    }
                }
            }
        }
        // Update cached states only when relevant connectivity values change
        .onAppear {
            updateCachedStates()
        }
        .onChange(of: connectivity.activeTransfers[audiobookId.uuidString]) { _, _ in
            hasActiveTransfer = connectivity.activeTransfers[audiobookId.uuidString] != nil
        }
        .onChange(of: connectivity.watchCachedAudiobookIds.contains(audiobookId.uuidString)) { _, newValue in
            isOnWatch = newValue
        }
    }
    
    private func updateCachedStates() {
        hasActiveTransfer = connectivity.activeTransfers[audiobookId.uuidString] != nil
        isOnWatch = connectivity.watchCachedAudiobookIds.contains(audiobookId.uuidString)
    }
    
    @ViewBuilder
    private var deleteOptionsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        // Set pending delete option and close sheet
                        pendingDeleteOption = false
                        showDeleteOptions = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title2)
                                .foregroundStyle(.orange)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Delete from iPhone")
                                    .font(.headline)
                            }
                        }
                    }
                    
                    Button(role: .destructive) {
                        // Set pending delete option and close sheet
                        pendingDeleteOption = true
                        showDeleteOptions = false
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "icloud")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Delete from All Devices")
                                    .font(.headline)
                            }
                        }
                    }
                } header: {
                    Text("Delete \"\(audiobook.title)\"?")
                }
                
                Section {
                    Button("Cancel", role: .cancel) {
                        pendingDeleteOption = nil
                        showDeleteOptions = false
                    }
                }
            }
            .navigationTitle("Delete Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
            .interactiveDismissDisabled(false) // Allow swipe to dismiss
        }
    }
    

    private func removeCacheFromiPhone() {
        Task {
            do {
                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                try cacheManager.deleteCachedFile(for: audiobook)
            } catch {
                await MainActor.run {
                    deleteErrorMessage = "Failed to remove cached file: \(error.localizedDescription)"
                    showDeleteError = true
                }
            }
        }
    }
    
    private func removeFromAppleWatch() {
        guard let session = connectivity.session, session.isReachable else {
            deleteErrorMessage = "Apple Watch is not reachable. Make sure it's nearby and unlocked."
            showDeleteError = true
            return
        }
                
        // Send delete command to Watch
        let message: [String: Any] = [
            "command": "deleteAudiobook",
            "audiobookId": audiobookId.uuidString
        ]
        
        session.sendMessage(message, replyHandler: { response in
            Task { @MainActor in
                if let success = response["success"] as? Bool, success {
                    // Update the cached book list
                    self.connectivity.watchCachedAudiobookIds.remove(self.audiobookId.uuidString)
                } else {
                    let errorMsg = response["error"] as? String ?? "Unknown error"
                    print("[LibraryView] Watch deletion failed: \(errorMsg)")
                    self.deleteErrorMessage = "Failed to delete from Watch: \(errorMsg)"
                    self.showDeleteError = true
                }
            }
        }) { error in
            Task { @MainActor in
                print("[LibraryView] Watch message failed: \(error)")
                self.deleteErrorMessage = "Failed to communicate with Watch: \(error.localizedDescription)"
                self.showDeleteError = true
            }
        }
    }

    @MainActor
    private func deleteAudiobook(audiobookId: UUID, deleteFromiCloud: Bool) async {
        isDeleting = true
                
        do {
            // CRITICAL: Fetch the audiobook by ID to ensure we're deleting the correct one
            // This prevents SwiftData from deleting the wrong item due to list reordering
            let descriptor = FetchDescriptor<Audiobook>(
                predicate: #Predicate { $0.id == audiobookId }
            )
            
            guard let audiobookToDelete = try modelContext.fetch(descriptor).first else {
                print("[LibraryView] ERROR: Audiobook not found for deletion: \(audiobookId)")
                throw NSError(
                    domain: "LibraryView",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Audiobook not found"]
                )
            }
                        
            let service = AudiobookLibraryService(modelContext: modelContext)
            try await service.deleteAudiobook(
                audiobookToDelete,
                deleteFromiCloud: deleteFromiCloud
            )
            
            isDeleting = false
            
        } catch {
            print("[LibraryView] Deletion failed: \(error)")
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
        HStack(spacing: 12) {
            // Artwork
            Group {
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.tertiary)

                        Image(systemName: "book.closed")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2)

            // Book info
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)


                // Author
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Progress indicator
                if let session = audiobook.playbackSession {
                    HStack(spacing: 6) {
                        ProgressView(value: session.progressPercentage, total: 100)
                            .tint(.accentColor)
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
}
