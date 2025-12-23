//
//  LibraryView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity

// MARK: - Production Wrapper (for Navigation)

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) private var audiobooks: [Audiobook]
    @State private var connectivity: iOSWatchConnectivityManager?

    var body: some View {
        Group {
            if let connectivity {
                LibraryViewContent(
                    audiobooks: audiobooks,
                    connectivity: connectivity,
                    modelContext: modelContext
                )
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
}

// MARK: - Generic Content View (Injectable)

struct LibraryViewContent<Connectivity: iOSWatchConnectivity & Observable>: View {
    let audiobooks: [Audiobook]
    @Bindable var connectivity: Connectivity
    let modelContext: ModelContext

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
                    libraryList
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
        .environment(connectivity)
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

    private var libraryList: some View {
        List {
            ForEach(filteredAudiobooks) { book in
                AudiobookCardWithMenu(audiobook: book, connectivity: connectivity, modelContext: modelContext)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .id(book.id)
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
struct AudiobookCardWithMenu<Connectivity: iOSWatchConnectivity & Observable>: View {
    let audiobook: Audiobook
    var connectivity: Connectivity
    let modelContext: ModelContext

    @State private var showDeleteOptions = false
    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var showWatchTransfer = false
    @State private var showCloudKitTransfer = false
    @State private var pendingDeleteOption: Bool?

    // CRITICAL: Capture audiobook ID at initialization to prevent SwiftData identity issues
    private let audiobookId: UUID

    // Cache the transfer states to prevent unnecessary re-renders
    @State private var hasActiveTransfer = false
    @State private var isOnWatch = false

    init(audiobook: Audiobook, connectivity: Connectivity, modelContext: ModelContext) {
        self.audiobook = audiobook
        self.connectivity = connectivity
        self.modelContext = modelContext
        self.audiobookId = audiobook.id // Capture ID immediately
    }
    
    var body: some View {
        NavigationLink(value: audiobook) {
            AudiobookCard(audiobook: audiobook)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Delete button - opens sheet with options
            if audiobook.isFileCached {
                Button {
                    removeCacheFromiPhone()
                } label: {
                    Label("Remove", systemImage: "iphone.slash")
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
                    Label("Delete", systemImage: "icloud.slash")
                }
                .tint(.red)
            }
            
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
                } else {
                    // Show both transfer options
                    // CloudKit transfer (fast, recommended)
                    Button {
                        showCloudKitTransfer = true
                    } label: {
                        Label("CloudKit", systemImage: "icloud.and.arrow.up")
                    }
                    .tint(.blue)
                    
                    // Bluetooth transfer (legacy)
                    Button {
                        showWatchTransfer = true
                    } label: {
                        Label("Bluetooth", systemImage: "applewatch")
                    }
                    .tint(.purple)
                }
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
        .sheet(isPresented: $showCloudKitTransfer) {
            NavigationStack {
                CloudKitTransferView(audiobook: audiobook)
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
                    .lineLimit(2, reservesSpace: true)
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

// MARK: - Previews

#Preview("Library with Books") {
    @Previewable @State var connectivity = PreviewiOSWatchConnectivity()

    return LibraryViewContent(
        audiobooks: PreviewData.audiobooks,
        connectivity: connectivity,
        modelContext: PreviewModelContext.shared
    )
}

#Preview("Empty Library") {
    @Previewable @State var connectivity = PreviewiOSWatchConnectivity()

    return LibraryViewContent(
        audiobooks: [],
        connectivity: connectivity,
        modelContext: PreviewModelContext.shared
    )
}
