//
//  Listen_ThisApp.swift
//  Listen This Watch App
//

import Combine
import SwiftData
import SwiftUI
import WatchConnectivity
internal import os

// Disambiguate WatchConnectivityManager for Watch target
typealias WatchManager = WatchConnectivityManager

@main
struct Listen_ThisWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self) var extensionDelegate
    @State private var watchConnectivityManager: WatchManager = .shared
    @State private var transferCheckTimer: Timer?
    @State private var cleanupTimer: Timer?
    @State private var storeRemoteChangeNotification: NSObjectProtocol?
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer

    init() {
        do {
            // All models in a single schema with CloudKit sync
            // Note: CacheEntry will sync via CloudKit, but this is acceptable
            // because the relationship is optional and device-specific cleanup
            // won't affect other devices' ability to maintain their own cache entries
            let schema = Schema([
                Audiobook.self,
                Chapter.self,
                PlaybackSession.self,
                CacheEntry.self,
                UserSettings.self,
            ])

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.anarkisti.Listen-This")
            )

            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchLibraryView()
                .environment(watchConnectivityManager)
                .onAppear {
                    // Configure SettingsManager with model context
                    SettingsManager.shared.configure(modelContext: modelContainer.mainContext)

                    // Configure the connectivity manager with model context
                    watchConnectivityManager.configure(modelContext: modelContainer.mainContext)

                    // Check for any ongoing or pending transfers
                    watchConnectivityManager.checkPendingTransfers()

                    // Perform initial cleanup of orphaned caches
                    Task {
                        await performOrphanedCacheCleanup()
                    }

                    // Start periodic transfer status logging
                    startTransferMonitoring()

                    // Start periodic orphaned cache cleanup (every 5 minutes)
                    startPeriodicCleanup()
                }
                .onDisappear {
                    stopTransferMonitoring()
                    stopPeriodicCleanup()
                    stopObservingCloudKitChanges()
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
        }
    }

    // MARK: - Transfer Monitoring

    private func startTransferMonitoring() {
        // Log transfer status every 10 seconds
        transferCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                _ = watchConnectivityManager.activeTransfers.count
            }
        }
    }

    private func stopTransferMonitoring() {
        transferCheckTimer?.invalidate()
        transferCheckTimer = nil
    }

    // MARK: - Orphaned Cache Cleanup

    private func startPeriodicCleanup() {
        // Clean up orphaned caches every 5 minutes
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
            Task { @MainActor in
                await performOrphanedCacheCleanup()
            }
        }
    }

    private func stopPeriodicCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }

    private func stopObservingCloudKitChanges() {
        if let observer = storeRemoteChangeNotification {
            NotificationCenter.default.removeObserver(observer)
            storeRemoteChangeNotification = nil
        }
    }

    // MARK: - Scene Phase Handling

    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        if newPhase == .background {
            // App entering background - save playback state and sync
            AppLogger.general.info("[WatchApp] Entering background, saving playback state")

            Task { @MainActor in
                // Save context to ensure latest data is persisted
                try? modelContainer.mainContext.save()

                // If Watch becomes reachable later, sync will happen automatically
                // via sessionReachabilityDidChange
                if watchConnectivityManager.isReachable {
                    AppLogger.general.info(
                        "[WatchApp] Watch is reachable, will sync on reconnection")
                }
            }
        } else if newPhase == .active && oldPhase == .background {
            // App becoming active from background
            AppLogger.general.info("[WatchApp] Becoming active from background")

            // Check if Watch Connectivity became reachable while we were in background
            if watchConnectivityManager.isReachable {
                AppLogger.general.info(
                    "[WatchApp] Watch is reachable after background, sync will trigger automatically"
                )
            }
        }
    }

    /// Removes cache files for audiobooks that no longer exist in the database
    /// This handles cases where the audiobook was deleted from iPhone while Watch was offline
    @MainActor
    private func performOrphanedCacheCleanup() async {
        AppLogger.cache.info("[WatchApp] Starting orphaned cache cleanup...")

        let context = modelContainer.mainContext

        // Get all audiobook IDs currently in database
        let descriptor = FetchDescriptor<Audiobook>()
        guard let audiobooks = try? context.fetch(descriptor) else {
            AppLogger.cache.warning("[WatchApp] Failed to fetch audiobooks")
            return
        }

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
            AppLogger.cache.info("[WatchApp] No cache directory found, nothing to clean")
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
            AppLogger.cache.warning("[WatchApp] Failed to read cache directory")
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
                    AppLogger.cache.info("[WatchApp] Removed orphaned cache: \(filename)")
                } catch {
                    AppLogger.cache.warning(
                        "[WatchApp] Failed to remove orphaned cache \(filename): \(error)")
                }
            }
        }

        // Also clean up orphaned CacheEntry records in database
        let cacheEntryDescriptor = FetchDescriptor<CacheEntry>()
        if let cacheEntries = try? context.fetch(cacheEntryDescriptor) {
            for entry in cacheEntries {
                // If the audiobook no longer exists, delete the cache entry
                if entry.audiobook == nil {
                    context.delete(entry)
                    AppLogger.cache.info(
                        "[WatchApp] Removed orphaned CacheEntry: \(entry.filePath)")
                }
            }

            try? context.save()
        }

        if removedCount > 0 {
            let freedSpaceMB = Double(freedSpace) / 1_000_000.0
            AppLogger.cache.info(
                "[WatchApp] Cleanup complete: removed \(removedCount) orphaned cache(s), freed \(String(format: "%.1f", freedSpaceMB)) MB"
            )

            // Update the cached book list sent to iPhone
            watchConnectivityManager.sendCachedAudiobookList()
        } else {
            AppLogger.cache.info("[WatchApp] No orphaned caches found")
        }
    }
}
