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

    private let downloadManager = AudiobookshelfDownloadManager.shared
    private let network = NetworkStatusMonitor.shared
    @State private var failedDownload: FailedDownload?

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

    /// Search, toolbar and the add/settings sheets sit on the container, not
    /// on each state, so a search with no matches keeps its search field.
    private func sidebarContent(connectivity: iOSWatchConnectivityManager) -> some View {
        Group {
            if filteredAudiobooks.isEmpty {
                if isSyncingInBackground {
                    skeletonLoadingView
                } else if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    emptyStateView
                }
            } else {
                libraryList(connectivity: connectivity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !network.isOnline {
                Label("Offline. Downloaded books still play.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
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
                // Unavailable while the synced library is still loading
                .disabled(isSyncingInBackground && audiobooks.isEmpty)

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

    @ViewBuilder
    private func libraryList(connectivity: iOSWatchConnectivityManager) -> some View {
        List(filteredAudiobooks, selection: $selectedAudiobook) { book in
            // Capture all values we need before any closures
            let bookId = book.id
            let isFileCached = book.isFileCached
            let canDownload = book.requiresStreaming && book.sourceIdentifier != nil

            LibraryRow(audiobook: book, connectivity: connectivity, downloadManager: downloadManager)
            .tag(book)
            // Leading edge (swipe right) - Common actions (full swipe supported)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                // Transfer to Watch - show for cached books when Watch is available
                // Use stable conditions (isPaired, isWatchAppInstalled, isFileCached) for showing the button
                // Use dynamic conditions (isOnWatch, isUploadedToCloudKit, hasActiveTransfer) only for disabling
                if connectivity.isPaired && connectivity.isWatchAppInstalled && isFileCached {
                    let hasActiveTransfer =
                        connectivity.activeTransfers[bookId.uuidString]?.isActive == true

                    // Deliberately no "already sent" state. Whether a book is
                    // still on the Watch can't be known reliably from here —
                    // three transfer routes, intermittent connectivity, and the
                    // Watch can delete its copy at any time — and getting it
                    // wrong used to *disable* this button, leaving no way to
                    // re-send. Transferring again is cheap and idempotent, so
                    // the action stays available and only an in-flight transfer
                    // changes it.
                    let label = hasActiveTransfer ? "Cancel" : "Transfer"
                    let icon = hasActiveTransfer ? "xmark.circle" : "applewatch"

                    Button {
                        if hasActiveTransfer {
                            connectivity.cancelTransfer(for: bookId.uuidString)
                        } else {
                            transferAudiobookId = bookId
                        }
                    } label: {
                        Label(label, systemImage: icon)
                    }
                    .tint(hasActiveTransfer ? .orange : .blue)
                }

                // Download for remote books - primary action for streamable content.
                // Like Transfer, it turns into Cancel while in flight rather than
                // disappearing.
                if canDownload {
                    let isDownloading = downloadManager.isDownloading(bookId)
                    Button {
                        toggleDownload(bookId)
                    } label: {
                        Label(
                            isDownloading ? "Cancel" : "Download",
                            systemImage: isDownloading ? "xmark.circle" : "arrow.down.circle"
                        )
                    }
                    .tint(isDownloading ? .orange : .green)
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
                contextMenuItems(
                    for: bookId, isFileCached: isFileCached, canDownload: canDownload,
                    connectivity: connectivity)
            }
        }
        .alert(
            "Download Failed",
            isPresented: .init(
                get: { failedDownload != nil },
                set: { if !$0 { failedDownload = nil } }
            ),
            presenting: failedDownload
        ) { failure in
            Button("Try Again") { toggleDownload(failure.audiobookId) }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.title): \(failure.message)")
        }
        .alert(
            "Couldn't Send to Watch",
            isPresented: .init(
                get: { connectivity.transferFailure != nil },
                set: { if !$0 { connectivity.transferFailure = nil } }
            ),
            presenting: connectivity.transferFailure
        ) { failure in
            Button("Try Again") { transferAudiobookId = failure.audiobookId }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text("\(failure.title): \(failure.message)")
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
                Text("Send to Apple Watch")
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
        for bookId: UUID, isFileCached: Bool, canDownload: Bool,
        connectivity: iOSWatchConnectivityManager
    ) -> some View {
        if canDownload {
            let isDownloading = downloadManager.isDownloading(bookId)
            Button {
                toggleDownload(bookId)
            } label: {
                Label(
                    isDownloading ? "Cancel Download" : "Download",
                    systemImage: isDownloading ? "xmark.circle" : "arrow.down.circle"
                )
            }
        }

        // Send to Watch - show for cached books when Watch is available
        if connectivity.isPaired && connectivity.isWatchAppInstalled && isFileCached {
            let hasActiveTransfer =
                connectivity.activeTransfers[bookId.uuidString]?.isActive == true

            // As with the swipe action: no "already on Watch" state, because it
            // can't be known reliably and being wrong blocked re-sending.
            Button {
                transferAudiobookId = bookId
            } label: {
                Label("Send to Watch", systemImage: "applewatch")
            }
            .disabled(hasActiveTransfer)
        }

        // Delete - always show in context menu
        Button(role: .destructive) {
            deleteAudiobookId = bookId
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// Start a server download, or cancel the one in flight.
    ///
    /// Goes through the shared manager so the transfer survives backgrounding,
    /// resumes after a dropped connection, and publishes byte progress for the
    /// row's ring.
    private func toggleDownload(_ bookId: UUID) {
        if downloadManager.isDownloading(bookId) {
            downloadManager.cancel(audiobookId: bookId)
            return
        }

        // Fetch fresh from the context to avoid detached-object crashes
        let descriptor = FetchDescriptor<Audiobook>(predicate: #Predicate { $0.id == bookId })
        guard let audiobook = try? modelContext.fetch(descriptor).first else {
            AppLogger.import.error("Audiobook not found for download")
            return
        }
        let title = audiobook.title

        Task {
            do {
                try await downloadManager.download(audiobook)
            } catch AudiobookshelfDownloadError.cancelled {
                // The user asked for it
            } catch AudiobookshelfDownloadError.alreadyInProgress {
                // A transfer from an earlier launch was adopted instead
            } catch {
                failedDownload = FailedDownload(
                    audiobookId: bookId, title: title, message: error.localizedDescription)
            }
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
            Text("Add audiobooks from iCloud Drive or connect to Audiobookshelf")
        } actions: {
            Button {
                showingAddBook = true
            } label: {
                Label("Add Audiobook", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
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

// MARK: - Failed Download

private struct FailedDownload {
    let audiobookId: UUID
    let title: String
    let message: String
}

// MARK: - Library Row Component

struct LibraryRow: View {
    let connectivity: iOSWatchConnectivityManager
    let downloadManager: AudiobookshelfDownloadManager

    // Captured values to prevent detached object crashes
    private let audiobookId: UUID
    private let title: String
    private let author: String
    private let artworkData: Data?
    private let duration: Double
    private let currentPosition: Double
    private let playabilityState: AudiobookPlayabilityState
    
    init(
        audiobook: Audiobook, connectivity: iOSWatchConnectivityManager,
        downloadManager: AudiobookshelfDownloadManager
    ) {
        self.connectivity = connectivity
        self.downloadManager = downloadManager
        
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
        // while a direct Watch transfer is in flight. A finished one lingers in
        // the dictionary briefly but no longer spins.
        let isWatchTransferring =
            connectivity.activeTransfers[audiobookId.uuidString]?.isActive == true
        AudiobookRowView(
            title: title,
            author: author,
            artworkData: artworkData,
            duration: duration,
            currentPosition: currentPosition,
            playabilityState: playabilityState,
            showProgress: true,
            isTransferring: downloadManager.isDownloading(audiobookId) || isWatchTransferring,
            // A determinate ring once the download knows its size; until then
            // (or when the server never says) the spinner badge stands in.
            transferProgress: TransferProgressCenter.shared.fraction(for: audiobookId)
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
