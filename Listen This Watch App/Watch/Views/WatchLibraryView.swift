//
//  WatchLibraryView.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

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

    // Sheet state - storing IDs instead of model objects to avoid SwiftData issues
    @State private var downloadOptionsAudiobookId: UUID?
    @State private var cloudKitDownloadAudiobookId: UUID?
    @State private var bluetoothDownloadAudiobookId: UUID?

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

            // Clean up orphaned cache files (files that no longer have audiobook entries)
            Task {
                await cleanupOrphanedCaches()
            }
        }
    }

    // MARK: - Orphaned Cache Cleanup

    /// Removes cache files for audiobooks that no longer exist in the database
    /// This handles cases where the audiobook was deleted from iPhone while Watch was offline
    @MainActor
    private func cleanupOrphanedCaches() async {
        AppLogger.cache.info("[WatchLibraryView] Starting orphaned cache cleanup...")

        // Build a set of known filenames (for faster lookup)
        var knownFilenames = Set<String>()
        for audiobook in audiobooks {
            if let filename = audiobook.filename {
                knownFilenames.insert(filename)
            }
        }

        // Get cache directory
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")

        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            AppLogger.cache.info("[WatchLibraryView] No cache directory found, nothing to clean")
            return
        }

        // Get all cached files
        guard
            let cachedFiles = try? FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            AppLogger.cache.warning("[WatchLibraryView] Failed to read cache directory")
            return
        }

        var removedCount = 0
        var freedSpace: Int64 = 0

        for fileURL in cachedFiles {
            // Get the full filename (e.g., "MyBook.m4b")
            let filename = fileURL.lastPathComponent

            // Check if this filename belongs to any audiobook
            if !knownFilenames.contains(filename) {
                // Orphaned cache file - delete it
                do {
                    // Get file size before deleting
                    if let fileSize = try? FileManager.default.attributesOfItem(
                        atPath: fileURL.path)[.size] as? Int64
                    {
                        freedSpace += fileSize
                    }

                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                    AppLogger.cache.info("[WatchLibraryView] Removed orphaned cache: \(filename)")
                } catch {
                    AppLogger.cache.warning(
                        "[WatchLibraryView] Failed to remove orphaned cache \(filename): \(error)"
                    )
                }
            }
        }

        if removedCount > 0 {
            let freedSpaceMB = Double(freedSpace) / 1_000_000.0
            AppLogger.cache.info(
                "[WatchLibraryView] Cleanup complete: removed \(removedCount) orphaned cache(s), freed \(String(format: "%.1f", freedSpaceMB)) MB"
            )

            // Update the cached book list sent to iPhone
            connectivity.sendCachedAudiobookList()
        } else {
            AppLogger.cache.info("[WatchLibraryView] No orphaned caches found")
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
    }

    // MARK: - Actions

    private func removeDownload(for audiobook: Audiobook) {
        AppLogger.cache.info("[WatchLibraryView] Removing cache for: \(audiobook.title)")
        AppLogger.cache.info(
            "[WatchLibraryView] Expected cache path: \(audiobook.expectedCachePath ?? "nil")")
        AppLogger.cache.info(
            "[WatchLibraryView] Cache entry path: \(audiobook.cacheEntry?.filePath ?? "nil")")
        AppLogger.cache.info("[WatchLibraryView] isFileCached before: \(audiobook.isFileCached)")

        // Remove the cache entry and file WITHOUT animation
        // Animation can cause SwiftData to have issues with the relationship updates
        if let cacheEntry = audiobook.cacheEntry {
            // Delete file at the stored path
            let storedFileURL = URL(fileURLWithPath: cacheEntry.filePath)
            AppLogger.cache.info(
                "[WatchLibraryView] Attempting to delete file at: \(storedFileURL.path)")
            do {
                try FileManager.default.removeItem(at: storedFileURL)
                AppLogger.cache.info(
                    "[WatchLibraryView] File deleted at stored path: \(storedFileURL.path)")
            } catch {
                AppLogger.cache.warning(
                    "[WatchLibraryView] File deletion failed at stored path: \(error)")
            }

            // ALSO delete file at expected cache path if different
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if expectedFileURL.path != storedFileURL.path {
                    AppLogger.cache.info(
                        "[WatchLibraryView] Paths differ! Also deleting at expected path: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        AppLogger.cache.info(
                            "[WatchLibraryView] File deleted at expected path: \(expectedPath)")
                    } catch {
                        AppLogger.cache.warning(
                            "[WatchLibraryView] File deletion failed at expected path: \(error)")
                    }
                }
            }

            // IMPORTANT: Clear the relationship BEFORE deleting the entry
            // This ensures SwiftData processes the changes in the correct order
            audiobook.cacheEntry = nil
            AppLogger.cache.info("[WatchLibraryView] Cache entry relationship cleared")

            // Remove cache entry
            modelContext.delete(cacheEntry)
            AppLogger.cache.info("[WatchLibraryView] Cache entry deleted from context")
        } else {
            AppLogger.cache.warning(
                "[WatchLibraryView] No cache entry found, but checking for orphaned file...")
            // No cache entry but file might exist at expected path
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    AppLogger.cache.info(
                        "[WatchLibraryView] Found orphaned file at expected path, deleting: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        AppLogger.cache.info("[WatchLibraryView] Orphaned file deleted")
                    } catch {
                        AppLogger.cache.warning(
                            "[WatchLibraryView] Orphaned file deletion failed: \(error)")
                    }
                }
            }
        }

        // Save changes WITHOUT triggering List animations
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            do {
                try modelContext.save()
                AppLogger.cache.info("[WatchLibraryView] Context saved successfully")
                AppLogger.cache.info(
                    "[WatchLibraryView] Audiobook still in DB: id=\(audiobook.id), title=\(audiobook.title), cacheEntry=\(audiobook.cacheEntry == nil ? "nil" : "exists")"
                )
            } catch {
                AppLogger.cache.error(
                    "[WatchLibraryView] Failed to save after cache deletion: \(error)")
            }
        }

        // Update cached audiobook list sent to iPhone
        connectivity.sendCachedAudiobookList()
    }
}

// MARK: - Audiobook Row With Actions

struct AudiobookRowWithActions: View {
    let audiobook: Audiobook
    let onTap: () -> Void
    let onShowDownloadOptions: (Audiobook) -> Void
    let modelContext: ModelContext

    @Environment(WatchConnectivityManager.self) private var connectivity

    // Capture audiobook ID at initialization
    private let audiobookId: UUID

    init(
        audiobook: Audiobook,
        onTap: @escaping () -> Void,
        onShowDownloadOptions: @escaping (Audiobook) -> Void,
        modelContext: ModelContext
    ) {
        self.audiobook = audiobook
        self.onTap = onTap
        self.onShowDownloadOptions = onShowDownloadOptions
        self.modelContext = modelContext
        self.audiobookId = audiobook.id
    }

    var hasActiveTransfer: Bool {
        connectivity.activeTransfers[audiobookId.uuidString] != nil
    }

    var body: some View {
        AudiobookRow(audiobook: audiobook)
            .onTapGesture {
                // Prevent opening player if file is not actually cached
                if audiobook.isFileCached {
                    onTap()
                } else {
                    // File doesn't exist - show download options
                    cleanupStaleCacheEntry()
                    onShowDownloadOptions(audiobook)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                // State 1: Active transfer - show cancel only
                if hasActiveTransfer {
                    Button(role: .destructive) {
                        connectivity.cancelTransfer(audiobookId: audiobook.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                }
                // State 2: Cached - show remove from watch
                else if audiobook.isFileCached {
                    Button(role: .destructive) {
                        removeDownload(for: audiobook)
                    } label: {
                        Label("Remove", systemImage: "applewatch.slash")
                    }
                    .tint(.red)
                }
                // State 3: Not cached - show download option
                else {
                    Button {
                        onShowDownloadOptions(audiobook)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.blue)
                }
            }
            .onAppear {
                // Clean up stale cache entries when view appears
                if !audiobook.isFileCached && audiobook.cacheEntry != nil {
                    cleanupStaleCacheEntry()
                }
            }
    }

    /// Clean up CacheEntry if file doesn't exist
    private func cleanupStaleCacheEntry() {
        guard let cacheEntry = audiobook.cacheEntry else { return }

        // Verify file really doesn't exist
        let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        AppLogger.cache.warning(
            "[WatchLibraryView] Cleaning up stale CacheEntry for: \(audiobook.title)")

        // Remove stale cache entry
        audiobook.cacheEntry = nil
        modelContext.delete(cacheEntry)

        do {
            try modelContext.save()
            AppLogger.cache.info("[WatchLibraryView] Stale cache entry removed")
        } catch {
            AppLogger.cache.error("[WatchLibraryView] Failed to remove stale cache entry: \(error)")
        }
    }

    private func removeDownload(for audiobook: Audiobook) {
        AppLogger.cache.info("[WatchLibraryView] Removing cache for: \(audiobook.title)")
        AppLogger.cache.info(
            "[WatchLibraryView] Expected cache path: \(audiobook.expectedCachePath ?? "nil")")
        AppLogger.cache.info(
            "[WatchLibraryView] Cache entry path: \(audiobook.cacheEntry?.filePath ?? "nil")")
        AppLogger.cache.info("[WatchLibraryView] isFileCached before: \(audiobook.isFileCached)")

        // Remove the cache entry and file WITHOUT animation
        // Animation can cause SwiftData to have issues with the relationship updates
        if let cacheEntry = audiobook.cacheEntry {
            // Delete file at the stored path
            let storedFileURL = URL(fileURLWithPath: cacheEntry.filePath)
            AppLogger.cache.info(
                "[WatchLibraryView] Attempting to delete file at: \(storedFileURL.path)")
            do {
                try FileManager.default.removeItem(at: storedFileURL)
                AppLogger.cache.info(
                    "[WatchLibraryView] File deleted at stored path: \(storedFileURL.path)")
            } catch {
                AppLogger.cache.warning(
                    "[WatchLibraryView] File deletion failed at stored path: \(error)")
            }

            // ALSO delete file at expected cache path if different
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if expectedFileURL.path != storedFileURL.path {
                    AppLogger.cache.info(
                        "[WatchLibraryView] Paths differ! Also deleting at expected path: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        AppLogger.cache.info(
                            "[WatchLibraryView] File deleted at expected path: \(expectedPath)")
                    } catch {
                        AppLogger.cache.warning(
                            "[WatchLibraryView] File deletion failed at expected path: \(error)")
                    }
                }
            }

            // IMPORTANT: Clear the relationship BEFORE deleting the entry
            // This ensures SwiftData processes the changes in the correct order
            audiobook.cacheEntry = nil
            AppLogger.cache.info("[WatchLibraryView] Cache entry relationship cleared")

            // Remove cache entry
            modelContext.delete(cacheEntry)
            AppLogger.cache.info("[WatchLibraryView] Cache entry deleted from context")
        } else {
            AppLogger.cache.warning(
                "[WatchLibraryView] No cache entry found, but checking for orphaned file...")
            // No cache entry but file might exist at expected path
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    AppLogger.cache.info(
                        "[WatchLibraryView] Found orphaned file at expected path, deleting: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        AppLogger.cache.info("[WatchLibraryView] Orphaned file deleted")
                    } catch {
                        AppLogger.cache.warning(
                            "[WatchLibraryView] Orphaned file deletion failed: \(error)")
                    }
                }
            }
        }

        // Save changes WITHOUT triggering List animations
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            do {
                try modelContext.save()
                AppLogger.cache.info("[WatchLibraryView] Context saved successfully")
                AppLogger.cache.info(
                    "[WatchLibraryView] Audiobook still in DB: id=\(audiobook.id), title=\(audiobook.title), cacheEntry=\(audiobook.cacheEntry == nil ? "nil" : "exists")"
                )
            } catch {
                AppLogger.cache.error(
                    "[WatchLibraryView] Failed to save after cache deletion: \(error)")
            }
        }

        // Update cached audiobook list sent to iPhone
        connectivity.sendCachedAudiobookList()
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
                ZStack(alignment: .bottomTrailing) {
                    if let artworkData = audiobook.artworkData,
                        let uiImage = UIImage(data: artworkData)
                    {
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
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(audiobook.title)
                        .font(.headline)
                        .lineLimit(2, reservesSpace: true)

                    Text(audiobook.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                }
            }
            // Status indicator
            if hasActiveTransfer {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 10))
                    Text("Downloading")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            } else if !audiobook.isFileCached {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 10))
                    Text("Not Downloaded")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
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

    @State private var cloudKitAvailability: ChunkAvailability = .notUploaded
    @State private var isCheckingAvailability = true

    var body: some View {
        VStack(spacing: 12) {
            // Header
            VStack(spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text("Choose Download Method")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if isCheckingAvailability {
                ProgressView()
                    .padding()
            } else {
                // CloudKit option
                DownloadOptionButton(
                    icon: "icloud.and.arrow.down.fill",
                    title: "iCloud WiFi",
                    subtitle: cloudKitAvailabilityText,
                    isAvailable: cloudKitAvailability == .fullyUploaded,
                    action: onSelectCloudKit
                )

                // Bluetooth option
                DownloadOptionButton(
                    icon: "iphone.and.arrow.right.outward",
                    title: "From iPhone",
                    subtitle: "Bluetooth transfer",
                    isAvailable: true,
                    action: onSelectBluetooth
                )
            }
        }
        .padding()
        .task {
            await checkCloudKitAvailability()
        }
    }

    private var cloudKitAvailabilityText: String {
        switch cloudKitAvailability {
        case .fullyUploaded:
            return "Ready to download"
        case .partiallyUploaded:
            return "Upload incomplete"
        case .notUploaded:
            return "Not uploaded yet"
        }
    }

    private func checkCloudKitAvailability() async {
        let transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
        cloudKitAvailability = await transferManager.checkCloudKitChunks(for: audiobook)
        isCheckingAvailability = false
    }
}

struct DownloadOptionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isAvailable: Bool
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
                    }

                    Text(subtitle)
                        .font(.system(size: 9))
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
            .background(isAvailable ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

#Preview {
    WatchLibraryView()
        .modelContainer(for: [Audiobook.self])
        .environment(WatchConnectivityManager.shared)
}
