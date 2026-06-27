//
//  WatchLibraryView.swift
//  Listen This Watch App
//

import Network
import Observation
import SwiftData
import SwiftUI
import WatchConnectivity
internal import os

struct WatchLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var connectivity

    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse)
    private var audiobooks: [Audiobook]

    @State private var selectedAudiobook: Audiobook?
    @State private var showingPlayer = false
    @State private var showingSettings = false

    // Sheet state - storing IDs instead of model objects to avoid SwiftData issues
    @State private var downloadOptionsAudiobookId: UUID?
    @State private var cloudKitDownloadAudiobookId: UUID?
    @State private var bluetoothDownloadAudiobookId: UUID?

    // Removal confirmation is owned here (not on the row) so presenting the
    // alert doesn't tear down the swiped row before it can show.
    @State private var removeDownloadAudiobookId: UUID?

    // Initial sync state
    @State private var isInitialSyncComplete = false

    var body: some View {
        NavigationStack {
            Group {
                if isInitialSyncComplete {
                    if audiobooks.isEmpty {
                        emptyStateView
                    } else {
                        audiobookList
                    }
                } else {
                    initialSyncLoadingView
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showingPlayer) {
                if let audiobook = selectedAudiobook {
                    WatchPlayerView(audiobook: audiobook)
                }
            }
            .navigationDestination(isPresented: $showingSettings) {
                AudiobookshelfWatchSettingsView()
            }
        }
        .task {
            connectivity.configure(modelContext: modelContext)

            // Wait for initial sync (grace period for CloudKit)
            await waitForInitialSync()

            // Send cached book list to iPhone when view appears
            connectivity.sendCachedAudiobookList()

            // Clean up orphaned cache files (files that no longer have audiobook entries)
            await cleanupOrphanedCaches()
        }
    }

    // MARK: - Initial Sync

    private var initialSyncLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Syncing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
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
            try? await Task.sleep(for: .seconds(1.5))
        } else {
            AppLogger.general.info("[Watch] No network connection, skipping initial sync wait")
        }

        isInitialSyncComplete = true
    }

    // MARK: - Orphaned Cache Cleanup

    /// Removes cache files for audiobooks that no longer exist in the database
    /// This handles cases where the audiobook was deleted from iPhone while Watch was offline
    @MainActor
    private func cleanupOrphanedCaches() async {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        let (removedCount, _) = await cacheManager.cleanupOrphanedCaches(audiobooks: audiobooks)

        // Update the cached book list sent to iPhone if anything was removed
        if removedCount > 0 {
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
                    },
                    onShowDownloadOptions: { audiobook in
                        downloadOptionsAudiobookId = audiobook.id
                    },
                    onRequestRemove: {
                        removeDownloadAudiobookId = audiobook.id
                    },
                    modelContext: modelContext
                )
                .id(audiobook.id)  // Explicit ID to maintain row identity
            }
        }
        .sheet(
            isPresented: .init(
                get: { downloadOptionsAudiobookId != nil },
                set: { if !$0 { downloadOptionsAudiobookId = nil } }
            )
        ) {
            if let id = downloadOptionsAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                DownloadOptionsSheet(
                    audiobook: audiobook,
                    onSelectCloudKit: {
                        cloudKitDownloadAudiobookId = id
                        downloadOptionsAudiobookId = nil
                    },
                    onSelectBluetooth: {
                        bluetoothDownloadAudiobookId = id
                        downloadOptionsAudiobookId = nil
                    }
                )
            }
        }
        .sheet(
            isPresented: .init(
                get: { cloudKitDownloadAudiobookId != nil },
                set: { if !$0 { cloudKitDownloadAudiobookId = nil } }
            )
        ) {
            if let id = cloudKitDownloadAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                NavigationStack {
                    CloudKitTransferView(audiobook: audiobook)
                }
            }
        }
        .sheet(
            isPresented: .init(
                get: { bluetoothDownloadAudiobookId != nil },
                set: { if !$0 { bluetoothDownloadAudiobookId = nil } }
            )
        ) {
            if let id = bluetoothDownloadAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                NavigationStack {
                    WatchTransferStatusView(audiobook: audiobook)
                }
            }
        }
        .confirmationDialog(
            "Remove Download",
            isPresented: .init(
                get: { removeDownloadAudiobookId != nil },
                set: { if !$0 { removeDownloadAudiobookId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let id = removeDownloadAudiobookId,
                    let audiobook = audiobooks.first(where: { $0.id == id })
                {
                    removeDownload(for: audiobook)
                }
                removeDownloadAudiobookId = nil
            }
            Button("Cancel", role: .cancel) { removeDownloadAudiobookId = nil }
        } message: {
            Text("This will remove the downloaded file from your Watch.")
        }
    }

    // MARK: - Actions

    private func removeDownload(for audiobook: Audiobook) {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)

        do {
            try cacheManager.removeCache(for: audiobook)
            // Update cached audiobook list sent to iPhone
            connectivity.sendCachedAudiobookList()
        } catch {
            AppLogger.cache.error("[WatchLibraryView] Failed to remove cache: \(error)")
        }
    }
}

// MARK: - Audiobook Row With Actions

struct AudiobookRowWithActions: View {
    let audiobook: Audiobook
    let onTap: () -> Void
    let onShowDownloadOptions: (Audiobook) -> Void
    let onRequestRemove: () -> Void
    let modelContext: ModelContext

    @Environment(WatchConnectivityManager.self) private var connectivity

    // Capture audiobook ID at initialization
    private let audiobookId: UUID

    init(
        audiobook: Audiobook,
        onTap: @escaping () -> Void,
        onShowDownloadOptions: @escaping (Audiobook) -> Void,
        onRequestRemove: @escaping () -> Void,
        modelContext: ModelContext
    ) {
        self.audiobook = audiobook
        self.onTap = onTap
        self.onShowDownloadOptions = onShowDownloadOptions
        self.onRequestRemove = onRequestRemove
        self.modelContext = modelContext
        self.audiobookId = audiobook.id
    }

    var hasActiveTransfer: Bool {
        connectivity.activeTransfers[audiobookId.uuidString] != nil
    }

    /// Whether the book is downloaded locally. Reading `cacheEntry` (a SwiftData
    /// relationship) registers an observation dependency so the row and its
    /// swipe buttons refresh when the download is removed; playabilityState
    /// alone reads the filesystem and isn't tracked, leaving stale button state.
    var isCached: Bool {
        audiobook.cacheEntry != nil && audiobook.playabilityState == .cached
    }

    var body: some View {
        AudiobookRow(audiobook: audiobook)
            .onTapGesture {
                // Check playability state
                if audiobook.playabilityState.isPlayable {
                    onTap()
                } else {
                    // Not playable - show download options
                    cleanupStaleCacheEntry()
                    onShowDownloadOptions(audiobook)
                }
            }
            // Leading edge (swipe right) - positive actions (Download).
            // Keep the button always present and use dynamic state only to
            // disable it: changing which swipe buttons exist between updates is
            // what triggers the List collection-view inconsistency crash.
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    onShowDownloadOptions(audiobook)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
                .disabled(hasActiveTransfer || isCached)
            }
            // Trailing edge (swipe left) - cancel or remove.
            // IMPORTANT: do NOT use role: .destructive here. A destructive swipe
            // action makes the List animate the row's removal when triggered,
            // but neither action deletes the library row (Remove only clears the
            // local download), so the data source still returns the same count
            // and UIKit throws an "invalid number of items" inconsistency. The
            // red tint conveys the destructive intent without that animation.
            // allowsFullSwipe is false for the same reason, and removal is
            // confirmed by the parent to avoid tearing down this row mid-present.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    if hasActiveTransfer {
                        connectivity.cancelTransfer(audiobookId: audiobook.id)
                    } else if isCached {
                        onRequestRemove()
                    }
                } label: {
                    Label(
                        hasActiveTransfer ? "Cancel" : "Remove",
                        systemImage: hasActiveTransfer ? "xmark.circle" : "applewatch.slash"
                    )
                }
                .tint(hasActiveTransfer ? .orange : .red)
                .disabled(!hasActiveTransfer && !isCached)
            }
            .onAppear {
                reconcileCacheState()
            }
    }

    /// Reconcile the cache entry with the file on disk when the row appears.
    /// Removes stale entries (no file) and adopts orphaned files (file but no
    /// entry, e.g. downloaded by an older build) so the row reflects reality.
    private func reconcileCacheState() {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        if !audiobook.isFileCached && audiobook.cacheEntry != nil {
            cacheManager.cleanupStaleCacheEntry(for: audiobook)
        } else if audiobook.isFileCached && audiobook.cacheEntry == nil {
            cacheManager.adoptOrphanedCacheFileIfNeeded(for: audiobook)
        }
    }

    /// Clean up CacheEntry if file doesn't exist
    private func cleanupStaleCacheEntry() {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        cacheManager.cleanupStaleCacheEntry(for: audiobook)
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
        AudiobookRowView(
            audiobook: audiobook,
            showProgress: false,
            isTransferring: hasActiveTransfer
        )
        .sheet(isPresented: $showingTransferSheet) {
            NavigationStack {
                WatchTransferStatusView(audiobook: audiobook)
            }
        }
    }

    @ViewBuilder
    private var cacheStatusBadge: some View {
        HStack(spacing: 4) {
            if audiobook.cacheFileURL != nil {
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

// MARK: - Download Options Sheet

struct DownloadOptionsSheet: View {
    let audiobook: Audiobook
    let onSelectCloudKit: () -> Void
    let onSelectBluetooth: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(WatchConnectivityManager.self) private var connectivity

    @State private var cloudKitAvailability: ChunkAvailability = .notUploaded
    @State private var isCheckingAvailability = true

    /// Determine which method to recommend based on conditions
    private var recommendedMethod: RecommendedTransferMethod {
        // If already uploaded to CloudKit, that's fastest
        if cloudKitAvailability == .fullyUploaded {
            return .wifi
        }
        // If iPhone is nearby, direct transfer works without needing iCloud storage
        if connectivity.isReachable {
            return .direct
        }
        // Neither available - no clear recommendation
        return .none
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            VStack(spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(
                    ByteCountFormatter.string(
                        fromByteCount: audiobook.fileSize,
                        countStyle: .file
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()

            if isCheckingAvailability {
                ProgressView()
                    .padding()
            } else {
                // WiFi option (CloudKit)
                DownloadOptionButton(
                    icon: "wifi",
                    title: "Fast Download",
                    subtitle: wifiOptionSubtitle,
                    isAvailable: cloudKitAvailability == .fullyUploaded,
                    isRecommended: recommendedMethod == .wifi,
                    action: onSelectCloudKit
                )

                // Direct transfer option (Bluetooth/WatchConnectivity)
                DownloadOptionButton(
                    icon: "iphone",
                    title: "Direct Transfer",
                    subtitle: directOptionSubtitle,
                    isAvailable: true,
                    isRecommended: recommendedMethod == .direct,
                    action: onSelectBluetooth
                )

                // Help text
                if cloudKitAvailability != .fullyUploaded {
                    Text("Fast Download requires uploading from iPhone first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
        .padding()
        .task {
            await checkCloudKitAvailability()
        }
    }

    private var wifiOptionSubtitle: String {
        switch cloudKitAvailability {
        case .fullyUploaded:
            return "Via WiFi"
        case .partiallyUploaded:
            return "Upload incomplete"
        case .notUploaded:
            return "Not uploaded yet"
        }
    }

    private var directOptionSubtitle: String {
        if connectivity.isReachable {
            return "iPhone nearby"
        } else {
            return "Bring iPhone closer"
        }
    }

    private func checkCloudKitAvailability() async {
        let transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
        cloudKitAvailability = await transferManager.checkCloudKitChunks(for: audiobook)
        isCheckingAvailability = false
    }
}

/// Which transfer method is recommended
private enum RecommendedTransferMethod {
    case wifi      // CloudKit - already uploaded
    case direct    // WatchConnectivity - iPhone nearby
    case none      // No clear recommendation
}

struct DownloadOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isAvailable: Bool
    var isRecommended: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isAvailable ? .blue : .gray)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.footnote)
                            .fontWeight(.semibold)

                        if isRecommended && isAvailable {
                            Text("Best")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isAvailable {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(buttonBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }

    private var buttonBackground: Color {
        if !isAvailable {
            return Color.gray.opacity(0.1)
        }
        if isRecommended {
            return Color.green.opacity(0.15)
        }
        return Color.blue.opacity(0.1)
    }
}

#if DEBUG
    #Preview("Mixed Library") {
        let container = try! ModelContainer(
            for: Audiobook.self, CacheEntry.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let context = ModelContext(container)

        // 1. Not synced iCloud book
        let hobbit = Audiobook(
            title: "The Hobbit",
            author: "J.R.R. Tolkien",
            narrator: "Andy Serkis",
            duration: 11 * 3600,
            fileSize: 450_000_000,
            iCloudRelativePath: "Documents/Audiobooks/The_Hobbit.m4b",
            chapterCount: 19
        )
        hobbit.lastAccessedDate = Date().addingTimeInterval(-3600)  // 1 hour ago

        // 2. Cached book
        let orwell = Audiobook(
            title: "1984",
            author: "George Orwell",
            narrator: "Simon Prebble",
            duration: 12 * 3600,
            fileSize: 480_000_000,
            iCloudRelativePath: "Documents/Audiobooks/1984.m4b",
            chapterCount: 24
        )
        orwell.lastAccessedDate = Date().addingTimeInterval(-7200)  // 2 hours ago

        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")
        let cacheURL = cacheDir.appendingPathComponent(orwell.filename ?? "1984.m4b")

        let cacheEntry = CacheEntry(
            filePath: cacheURL.path,
            fileSize: orwell.fileSize,
            downloadedDate: Date().addingTimeInterval(-86400)
        )
        orwell.cacheEntry = cacheEntry

        // 3. Streamable book
        let gatsby = Audiobook(
            title: "The Great Gatsby",
            author: "F. Scott Fitzgerald",
            narrator: "Jake Gyllenhaal",
            duration: 5 * 3600,
            fileSize: 200_000_000
        )
        gatsby.sourceType = "audiobookshelf"
        gatsby.sourceIdentifier = "li_1234567890"
        gatsby.sourceURL = "https://abs.example.com/api/items/li_1234567890/file"
        gatsby.chapterCount = 9
        gatsby.lastAccessedDate = Date()  // Most recent

        context.insert(hobbit)
        context.insert(orwell)
        context.insert(cacheEntry)
        context.insert(gatsby)
        try! context.save()

        let connectivity = WatchConnectivityManager.shared
        connectivity.configure(modelContext: context)

        return WatchLibraryView()
            .modelContainer(container)
            .environment(connectivity)
    }

#endif
