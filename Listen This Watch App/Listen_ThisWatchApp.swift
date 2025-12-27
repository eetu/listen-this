//
//  Listen_ThisApp.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity
import Combine

// Disambiguate WatchConnectivityManager for Watch target
typealias WatchManager = WatchConnectivityManager

@main
struct Listen_ThisWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self) var extensionDelegate
    @State private var watchConnectivityManager: WatchManager = .shared
    @State private var transferCheckTimer: Timer?
    @State private var cleanupTimer: Timer?
    @State private var storeRemoteChangeNotification: NSObjectProtocol?

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
                CacheEntry.self
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
    
    /// Removes cache files for audiobooks that no longer exist in the database
    /// This handles cases where the audiobook was deleted from iPhone while Watch was offline
    @MainActor
    private func performOrphanedCacheCleanup() async {
        print("🧹 [WatchApp] Starting orphaned cache cleanup...")
        
        let context = modelContainer.mainContext
        
        // Get all audiobook IDs currently in database
        let descriptor = FetchDescriptor<Audiobook>()
        guard let audiobooks = try? context.fetch(descriptor) else {
            print("⚠️ [WatchApp] Failed to fetch audiobooks")
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
            print("✅ [WatchApp] No cache directory found, nothing to clean")
            return
        }

        // Get all cached files
        guard let cachedFiles = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("⚠️ [WatchApp] Failed to read cache directory")
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
                    if let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
                        freedSpace += fileSize
                    }
                    
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                    print("🗑️ [WatchApp] Removed orphaned cache: \(filename)")
                } catch {
                    print("⚠️ [WatchApp] Failed to remove orphaned cache \(filename): \(error)")
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
                    print("🗑️ [WatchApp] Removed orphaned CacheEntry: \(entry.filePath)")
                }
            }
            
            try? context.save()
        }
        
        if removedCount > 0 {
            let freedSpaceMB = Double(freedSpace) / 1_000_000.0
            print("✅ [WatchApp] Cleanup complete: removed \(removedCount) orphaned cache(s), freed \(String(format: "%.1f", freedSpaceMB)) MB")
            
            // Update the cached book list sent to iPhone
            watchConnectivityManager.sendCachedAudiobookList()
        } else {
            print("✅ [WatchApp] No orphaned caches found")
        }
    }
}
