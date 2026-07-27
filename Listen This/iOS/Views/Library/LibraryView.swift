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
    @State private var isSyncingInBackground = false
    
    // Watch transfer hint
    @AppStorage("hasSeenWatchTransferHint") private var hasSeenWatchTransferHint = false
    @State private var showWatchTransferHint = false

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
        .onChange(of: audiobooks) { _, newBooks in
            // Clear selection if the selected audiobook was deleted (e.g., via CloudKit sync)
            if let selected = selectedAudiobook,
               !newBooks.contains(where: { $0.id == selected.id }) {
                selectedAudiobook = nil
            }
            // Also clear any sheet states for deleted books
            if let id = deleteAudiobookId, !newBooks.contains(where: { $0.id == id }) {
                deleteAudiobookId = nil
            }
            if let id = transferAudiobookId, !newBooks.contains(where: { $0.id == id }) {
                transferAudiobookId = nil
            }
            if let id = detailsAudiobookId, !newBooks.contains(where: { $0.id == id }) {
                detailsAudiobookId = nil
            }
        }
    }

    @ViewBuilder
    private func sidebarContent(connectivity: iOSWatchConnectivityManager) -> some View {
        if filteredAudiobooks.isEmpty {
            if isSyncingInBackground {
                skeletonLoadingView
            } else {
                emptyStateView
            }
        } else {
            libraryList(connectivity: connectivity)
        }
    }

    @ViewBuilder
    private func libraryList(connectivity: iOSWatchConnectivityManager) -> some View {
        List(filteredAudiobooks, selection: $selectedAudiobook) { book in
            // Capture all values we need before any closures
            let bookId = book.id
            let isFileCached = book.isFileCached
            let requiresStreaming = book.requiresStreaming
            let sourceIdentifier = book.sourceIdentifier
            
            LibraryRow(
                audiobook: book, connectivity: connectivity, downloadingBookIds: downloadingBookIds
            )
            .tag(book)
            // Leading edge (swipe right) - Common actions (full swipe supported)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Transfer to Watch - show for cached books when Watch is available
                // Use stable conditions (isPaired, isWatchAppInstalled, isFileCached) for showing the button
                // Use dynamic conditions (isOnWatch, isUploadedToCloudKit, hasActiveTransfer) only for disabling
                if connectivity.isPaired && connectivity.isWatchAppInstalled && isFileCached {
                    let isOnWatch = connectivity.watchCachedAudiobookIds.contains(bookId.uuidString)
                    let isUploadedToCloudKit = connectivity.cloudKitUploadedAudiobookIds.contains(bookId.uuidString)
                    let hasActiveTransfer = connectivity.activeTransfers[bookId.uuidString] != nil
                    let isOnWatchOrCloud = isOnWatch || isUploadedToCloudKit

                    // One button that morphs by state (keeps swipe membership
                    // stable): Cancel while transferring, Sent (disabled) once on
                    // the Watch/CloudKit, otherwise Transfer.
                    let label = hasActiveTransfer ? "Cancel" : (isOnWatchOrCloud ? "Sent" : "Transfer")
                    let icon = hasActiveTransfer
                        ? "xmark.circle"
                        : (isOnWatchOrCloud ? "checkmark" : "applewatch")

                    Button {
                        if hasActiveTransfer {
                            connectivity.cancelTransfer(for: bookId.uuidString)
                        } else {
                            transferAudiobookId = bookId
                        }
                    } label: {
                        Label(label, systemImage: icon)
                    }
                    .tint(hasActiveTransfer ? .orange : (isOnWatchOrCloud ? .gray : .blue))
                    .disabled(!hasActiveTransfer && isOnWatchOrCloud)
                }

                // Download for remote books - primary action for streamable content
                if requiresStreaming && sourceIdentifier != nil {
                    Button {
                        downloadingBookIds.insert(bookId)
                        Task {
                            await downloadRemoteBookById(bookId)
                            downloadingBookIds.remove(bookId)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.green)
                    .disabled(downloadingBookIds.contains(bookId))
                }
            }
            // Trailing edge (swipe left) - Info & Delete
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // Delete action - leftmost, supports full swipe
                Button(role: .destructive) {
                    deleteAudiobookId = bookId
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                // Info/Details action - rightmost
                Button {
                    detailsAudiobookId = bookId
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .tint(.blue)
            }
            .contextMenu {
                contextMenuItems(for: bookId, isFileCached: isFileCached, connectivity: connectivity)
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
                get: { 
                    // Only show sheet if audiobook still exists
                    guard let id = deleteAudiobookId else { return false }
                    return audiobooks.contains(where: { $0.id == id })
                },
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
                        // Clear selection if deleted book was selected
                        if selectedAudiobook?.id == id {
                            selectedAudiobook = nil
                        }
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
        .safeAreaInset(edge: .bottom) {
            if showWatchTransferHint {
                watchTransferHintBanner(connectivity: connectivity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            checkWatchTransferHint(connectivity: connectivity)
        }
        .onChange(of: audiobooks) { _, _ in
            checkWatchTransferHint(connectivity: connectivity)
        }
    }
    
    private func checkWatchTransferHint(connectivity: iOSWatchConnectivityManager) {
        guard !hasSeenWatchTransferHint else { return }
        guard connectivity.isPaired && connectivity.isWatchAppInstalled else { return }
        
        // Check if any book is cached and ready for transfer
        let hasCachedBooks = audiobooks.contains { $0.isFileCached }
        
        if hasCachedBooks {
            withAnimation(.easeInOut(duration: 0.3).delay(0.5)) {
                showWatchTransferHint = true
            }
        }
    }
    
    @ViewBuilder
    private func watchTransferHintBanner(connectivity: iOSWatchConnectivityManager) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Transfer to Apple Watch")
                    .font(.subheadline.weight(.medium))
                Text("Swipe right on any audiobook to send it to your Watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                withAnimation {
                    hasSeenWatchTransferHint = true
                    showWatchTransferHint = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    @ViewBuilder
    private func contextMenuItems(
        for bookId: UUID, isFileCached: Bool, connectivity: iOSWatchConnectivityManager
    ) -> some View {
        // Send to Watch - show for cached books when Watch is available
        if connectivity.isPaired && connectivity.isWatchAppInstalled && isFileCached {
            let isOnWatch = connectivity.watchCachedAudiobookIds.contains(bookId.uuidString)
            let isUploadedToCloudKit = connectivity.cloudKitUploadedAudiobookIds.contains(bookId.uuidString)
            let hasActiveTransfer = connectivity.activeTransfers[bookId.uuidString] != nil
            let isAlreadyTransferred = isOnWatch || isUploadedToCloudKit || hasActiveTransfer
            
            Button {
                transferAudiobookId = bookId
            } label: {
                Label(isAlreadyTransferred ? "Already on Watch" : "Send to Watch", 
                      systemImage: isAlreadyTransferred ? "checkmark.circle" : "applewatch")
            }
            .disabled(isAlreadyTransferred)
        }

        // Delete - always show in context menu
        Button(role: .destructive) {
            deleteAudiobookId = bookId
        } label: {
            Label("Delete", systemImage: "trash")
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

    private func downloadRemoteBookById(_ bookId: UUID) async {
        // Fetch the audiobook fresh from context to avoid detached object issues
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.id == bookId }
        )
        guard let audiobook = try? modelContext.fetch(descriptor).first else {
            AppLogger.import.error("Audiobook not found for download")
            return
        }
        await downloadRemoteBook(audiobook)
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
                let provider = try await AudiobookshelfProvider.authenticatedFromSettings()
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
        ContentUnavailableView {
            Label("Syncing Library", systemImage: "icloud.and.arrow.down")
        } description: {
            Text("Checking iCloud for your audiobooks...")
        }
    }
    
    private var skeletonLoadingView: some View {
        List {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonRow()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    // Disabled during sync
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .disabled(true)

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing from iCloud...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
        }
    }

    /// Key to track if user has ever had audiobooks (persists across reinstalls via iCloud KVS)
    private static let hasEverHadAudiobooksKey = "hasEverHadAudiobooks"
    
    /// Wait for initial CloudKit sync with adaptive grace period
    /// - Uses longer wait time for fresh installs (no local data)
    /// - Skips if no network connection to allow offline playback
    private func waitForInitialSync() async {
        // Check if we have any local data already
        let hasLocalData = !audiobooks.isEmpty
        
        if hasLocalData {
            // Data exists locally, no need to wait for sync
            // Also mark that user has had audiobooks before
            NSUbiquitousKeyValueStore.default.set(true, forKey: Self.hasEverHadAudiobooksKey)
            AppLogger.general.info("Local data exists, skipping sync wait")
            isInitialSyncComplete = true
            return
        }
        
        // Check if user has ever had audiobooks on any device
        // This persists via iCloud Key-Value Store across reinstalls
        let hasEverHadAudiobooks = NSUbiquitousKeyValueStore.default.bool(forKey: Self.hasEverHadAudiobooksKey)
        
        if !hasEverHadAudiobooks {
            // Truly new user - skip sync wait entirely, show empty state
            AppLogger.general.info("New user detected, skipping sync wait")
            isInitialSyncComplete = true
            return
        }
        
        // User has had audiobooks before - wait for CloudKit sync
        AppLogger.general.info("Returning user detected, waiting for CloudKit sync")
        
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
            // Returning user with network - wait for CloudKit sync
            let initialWait: Double = 2.0
            let pollInterval: Double = 0.5
            var elapsed: Double = 0
            
            while elapsed < initialWait {
                try? await Task.sleep(for: .seconds(pollInterval))
                elapsed += pollInterval
                
                if !audiobooks.isEmpty {
                    AppLogger.general.info("CloudKit sync completed after \(elapsed)s")
                    isInitialSyncComplete = true
                    return
                }
            }
            
            // Show skeleton UI and continue syncing in background
            AppLogger.general.info("Showing skeleton UI, continuing sync in background")
            isInitialSyncComplete = true
            isSyncingInBackground = true
            
            // Continue waiting in background for up to 30 seconds for returning users
            let maxBackgroundWait: Double = 30.0
            while elapsed < maxBackgroundWait {
                try? await Task.sleep(for: .seconds(1.0))
                elapsed += 1.0
                
                if !audiobooks.isEmpty {
                    AppLogger.general.info("CloudKit sync completed after \(elapsed)s (background)")
                    isSyncingInBackground = false
                    return
                }
            }
            
            // Give up - maybe user deleted all their audiobooks
            AppLogger.general.info("No audiobooks found after \(elapsed)s, showing empty state")
            isSyncingInBackground = false
        } else {
            AppLogger.general.info("No network connection, skipping initial sync wait")
            isInitialSyncComplete = true
        }
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
    }
}

// MARK: - Skeleton Row Component

struct SkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 12) {
            // Artwork placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 60, height: 60)
            
            VStack(alignment: .leading, spacing: 8) {
                // Title placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 180, height: 16)
                
                // Author placeholder
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 120, height: 14)
                
                // Progress placeholder
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 4)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(isAnimating ? 0.5 : 1.0)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
            value: isAnimating
        )
        .onAppear {
            // Skip the pulsing animation entirely when Reduce Motion is on.
            isAnimating = !reduceMotion
        }
    }
}

// MARK: - Library Row Component

struct LibraryRow: View {
    let connectivity: iOSWatchConnectivityManager
    let downloadingBookIds: Set<UUID>
    
    // Captured values to prevent detached object crashes
    private let audiobookId: UUID
    private let title: String
    private let author: String
    private let artworkData: Data?
    private let duration: Double
    private let currentPosition: Double
    private let playabilityState: AudiobookPlayabilityState
    
    init(audiobook: Audiobook, connectivity: iOSWatchConnectivityManager, downloadingBookIds: Set<UUID>) {
        self.connectivity = connectivity
        self.downloadingBookIds = downloadingBookIds
        
        // Capture values at init to resolve faults and prevent crashes
        self.audiobookId = audiobook.id
        self.title = audiobook.title
        self.author = audiobook.author
        // Access artworkData to resolve the fault - this is critical for CloudKit-synced books
        self.artworkData = audiobook.artworkData
        self.duration = audiobook.duration
        self.currentPosition = audiobook.playbackSession?.currentPosition ?? 0
        self.playabilityState = audiobook.playabilityState
    }

    var body: some View {
        // Reading activeTransfers here observes it, so the spinner badge appears
        // while a direct Watch transfer is in flight (not just remote downloads).
        let isWatchTransferring = connectivity.activeTransfers[audiobookId.uuidString] != nil
        AudiobookRowView(
            title: title,
            author: author,
            artworkData: artworkData,
            duration: duration,
            currentPosition: currentPosition,
            playabilityState: playabilityState,
            showProgress: true,
            isTransferring: downloadingBookIds.contains(audiobookId) || isWatchTransferring
        )
    }
}

#if DEBUG
#Preview {
    @Previewable @State var selectedAudiobook: Audiobook?

    let container = try! previewLibraryContainer()

    NavigationStack {
        LibraryView(selectedAudiobook: $selectedAudiobook)
            .modelContainer(container)
    }
}
#endif
