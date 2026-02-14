//
//  LibraryView.swift
//  Listen This
//
//  Main library view showing audiobook collection
//

import Network
import OSLog
import SwiftData
import SwiftUI

struct LibraryView: View {
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
    @State private var detailsAudiobookId: UUID?

    // Track books currently downloading
    @State private var downloadingBookIds: Set<UUID> = []

    // Initial sync state
    @State private var isInitialSyncComplete = false

    var filteredAudiobooks: [Audiobook] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText)
                || book.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if let connectivity {
                if isInitialSyncComplete {
                    sidebarContent(connectivity: connectivity)
                } else {
                    initialSyncLoadingView
                }
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

            // Wait for initial sync (grace period for CloudKit)
            await waitForInitialSync()

            // Clean up orphaned caches on view appearance
            await cleanupOrphanedCaches()
        }
    }

    @ViewBuilder
    private func sidebarContent(connectivity: iOSWatchConnectivityManager) -> some View {
        if filteredAudiobooks.isEmpty {
            emptyStateView
        } else {
            libraryList(connectivity: connectivity)
        }
    }

    @ViewBuilder
    private func libraryList(connectivity: iOSWatchConnectivityManager) -> some View {
        List(filteredAudiobooks, selection: $selectedAudiobook) { book in
            LibraryRow(
                audiobook: book, connectivity: connectivity, downloadingBookIds: downloadingBookIds
            )
            .tag(book)
            // Leading edge (swipe right) - Common actions (full swipe supported)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Transfer to Watch (only for cached books) - primary action
                if connectivity.isPaired && connectivity.isWatchAppInstalled
                    && book.isFileCached
                {
                    Button {
                        transferAudiobookId = book.id
                    } label: {
                        Label("Transfer", systemImage: "applewatch")
                    }
                    .tint(.blue)
                }

                // Download for remote books - primary action for streamable content
                if book.requiresStreaming && book.sourceIdentifier != nil {
                    Button {
                        Task {
                            await downloadRemoteBook(book)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.green)
                    .disabled(downloadingBookIds.contains(book.id))
                }
            }
            // Trailing edge (swipe left) - Info & Delete
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // Delete action - leftmost, supports full swipe
                Button(role: .destructive) {
                    deleteAudiobookId = book.id
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                // Info/Details action - rightmost
                Button {
                    detailsAudiobookId = book.id
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .tint(.blue)
            }
            .contextMenu {
                contextMenuItems(for: book, connectivity: connectivity)
            }
        }
        .refreshable {
            await refreshLibrary()
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
        .sheet(
            isPresented: .init(
                get: { deleteAudiobookId != nil },
                set: { if !$0 { deleteAudiobookId = nil } }
            )
        ) {
            if let id = deleteAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                DeleteAudiobookSheet(
                    audiobook: audiobook,
                    connectivity: connectivity,
                    modelContext: modelContext,
                    onDismiss: {
                        deleteAudiobookId = nil
                    }
                )
            }
        }
        .sheet(
            isPresented: .init(
                get: { transferAudiobookId != nil },
                set: { if !$0 { transferAudiobookId = nil } }
            )
        ) {
            if let id = transferAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                NavigationStack {
                    AutoTransferSheet(audiobook: audiobook)
                }
            }
        }
        .sheet(
            isPresented: .init(
                get: { detailsAudiobookId != nil },
                set: { if !$0 { detailsAudiobookId = nil } }
            )
        ) {
            if let id = detailsAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                AudiobookDetailsSheet(audiobook: audiobook)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(
        for audiobook: Audiobook, connectivity: iOSWatchConnectivityManager
    ) -> some View {
        // Send to Watch (only for cached books)
        if connectivity.isPaired && connectivity.isWatchAppInstalled && audiobook.isFileCached {
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

    private func refreshLibrary() async {
        // Force a refresh by triggering SwiftData to re-evaluate queries
        // This is useful after downloads or external changes
        do {
            try modelContext.save()
        } catch {
            AppLogger.import.error("Failed to refresh library: \(error.localizedDescription)")
        }
    }

    private func downloadRemoteBook(_ audiobook: Audiobook) async {
        guard let identifier = audiobook.sourceIdentifier else {
            AppLogger.import.error("Missing source identifier for download")
            return
        }

        // Mark as downloading
        downloadingBookIds.insert(audiobook.id)
        defer {
            // Always remove from downloading set when done
            downloadingBookIds.remove(audiobook.id)
        }

        do {
            let downloadURL: URL

            // Get download URL based on source type
            switch audiobook.sourceType {
            case "audiobookshelf":
                guard let serverURL = URL(string: SettingsManager.shared.audiobookshelfServerURL)
                else {
                    AppLogger.import.error("Missing Audiobookshelf server URL")
                    return
                }

                let settings = SettingsManager.shared

                let provider = AudiobookshelfProvider()
                try await provider.authenticateWithAPIKey(
                    serverURL: serverURL, apiKey: settings.audiobookshelfAPIKey)
                downloadURL = try await provider.getStreamURL(identifier: identifier)

            case "jellyfin":
                // Future: Add Jellyfin support
                AppLogger.import.error("Jellyfin downloads not yet supported")
                return

            default:
                AppLogger.import.error("Unknown source type: \(audiobook.sourceType)")
                return
            }

            // Download the file
            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)

            // Move to cache
            let cacheManager = AudiobookCacheManager(modelContext: modelContext)
            let cacheURL = try cacheManager.cacheAudiobook(audiobook, from: localURL)

            if cacheURL.path != audiobook.expectedCachePath,
                let expectedPath = audiobook.expectedCachePath
            {
                let expectedURL = URL(fileURLWithPath: expectedPath)
                try? FileManager.default.removeItem(at: expectedURL)
                try FileManager.default.moveItem(at: cacheURL, to: expectedURL)
            }

            // Create or update CacheEntry to trigger UI update
            let fileSize =
                try FileManager.default.attributesOfItem(
                    atPath: audiobook.expectedCachePath ?? ""
                )[.size] as? Int64 ?? 0

            if let existingEntry = audiobook.cacheEntry {
                // Update existing entry
                existingEntry.lastAccessedDate = Date()
                existingEntry.fileSize = fileSize
            } else {
                // Create new cache entry
                let cacheEntry = CacheEntry(
                    filePath: audiobook.expectedCachePath ?? "",
                    fileSize: fileSize,
                    downloadedDate: Date(),
                    lastAccessedDate: Date()
                )
                cacheEntry.audiobook = audiobook
                audiobook.cacheEntry = cacheEntry
                modelContext.insert(cacheEntry)
            }

            try modelContext.save()

            AppLogger.import.info("Downloaded remote book: \(audiobook.title)")
        } catch {
            AppLogger.import.error(
                "Failed to download remote book: \(error.localizedDescription)")
        }
    }

    // MARK: - Initial Sync

    private var initialSyncLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
        }
    }

    /// Wait for initial CloudKit sync with a grace period
    /// Skips if no network connection to allow offline playback of cached books
    private func waitForInitialSync() async {
        // Check network availability
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkMonitor")

        let hasNetwork = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            monitor.pathUpdateHandler = { path in
                resumed.withLock { wasResumed in
                    if !wasResumed {
                        wasResumed = true
                        continuation.resume(returning: path.status == .satisfied)
                        monitor.cancel()
                    }
                }
            }
            monitor.start(queue: queue)

            // Timeout after 0.5 seconds
            queue.asyncAfter(deadline: .now() + 0.5) {
                resumed.withLock { wasResumed in
                    if !wasResumed {
                        wasResumed = true
                        continuation.resume(returning: false)
                        monitor.cancel()
                    }
                }
            }
        }

        if hasNetwork {
            // Use a short grace period to allow CloudKit to sync initial data
            // If data already exists locally, this will be quick
            try? await Task.sleep(for: .seconds(1.5))
        } else {
            AppLogger.general.info("No network connection, skipping initial sync wait")
        }

        isInitialSyncComplete = true
    }

    // MARK: - Cache Cleanup

    /// Removes cache files for audiobooks that no longer exist in the database
    /// This handles cases where audiobooks were deleted while offline or due to sync issues
    private func cleanupOrphanedCaches() async {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        let _ = await cacheManager.cleanupOrphanedCaches(audiobooks: audiobooks)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Audiobooks", systemImage: "books.vertical")
        } description: {
            if searchText.isEmpty {
                Text("Add audiobooks from iCloud Drive or connect to Audiobookshelf")
            } else {
                Text("No audiobooks match \"\(searchText)\"")
            }
        } actions: {
            if searchText.isEmpty {
                Button {
                    showingAddBook = true
                } label: {
                    Label("Add Audiobook", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Library Row Component

struct LibraryRow: View {
    let audiobook: Audiobook
    let connectivity: iOSWatchConnectivityManager
    let downloadingBookIds: Set<UUID>

    var body: some View {
        AudiobookRowView(
            audiobook: audiobook,
            showProgress: true,
            isTransferring: downloadingBookIds.contains(audiobook.id)
        )
    }
}

#Preview {
    @Previewable @State var selectedAudiobook: Audiobook?

    let container = try! previewLibraryContainer()

    NavigationStack {
        LibraryView(selectedAudiobook: $selectedAudiobook)
            .modelContainer(container)
    }
}
