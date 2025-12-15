//
//  WatchDownloadManager.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import Foundation
import SwiftData

/// Manages audiobook downloads and cache on Apple Watch
@MainActor
class WatchDownloadManager {
    
    // MARK: - Configuration
    
    private let maxCacheSizeWatch: Int64 = 3 * 1024 * 1024 * 1024  // 3GB
    private let maxBooksWatch = 3
    private let modelContext: ModelContext
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Public Interface
    
    /// Download an audiobook to local cache
    func downloadBook(_ audiobook: Audiobook, progressHandler: @escaping (Double) -> Void) async throws {
        // Check if we can cache
        guard canCache(audiobook) else {
            throw AudiobookError.insufficientSpace
        }
        
        // Run cleanup if needed
        let requiredSpace = audiobook.fileSize
        let available = getAvailableSpace()
        
        if available < requiredSpace {
            try await runCleanup(requiredSpace: requiredSpace)
        }
        
        // Download from source
        guard let sourceURL = URL(string: audiobook.sourcePath) else {
            throw AudiobookError.invalidSource
        }
        
        let downloadedURL = try await downloadFile(from: sourceURL, progressHandler: progressHandler)
        
        // Move to permanent location
        let destinationURL = getCacheDirectory()
            .appendingPathComponent("\(audiobook.id.uuidString).m4b")
        
        try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
        
        // Update audiobook record
        audiobook.localFilePath = destinationURL.path
        audiobook.isCached = true
        audiobook.downloadDate = Date()
        audiobook.lastAccessedDate = Date()
        
        // Create cache entry
        let cacheEntry = CacheEntry()
        cacheEntry.filePath = destinationURL.path
        cacheEntry.fileSize = audiobook.fileSize
        cacheEntry.downloadedDate = Date()
        cacheEntry.lastAccessedDate = Date()
        cacheEntry.audiobook = audiobook
        
        audiobook.cacheEntry = cacheEntry
        modelContext.insert(cacheEntry)
        
        try modelContext.save()
    }
    
    /// Remove an audiobook from cache
    func removeFromCache(_ audiobook: Audiobook) throws {
        guard let localPath = audiobook.localFilePath else { return }
        
        let url = URL(fileURLWithPath: localPath)
        try FileManager.default.removeItem(at: url)
        
        audiobook.localFilePath = nil
        audiobook.isCached = false
        
        if let cacheEntry = audiobook.cacheEntry {
            modelContext.delete(cacheEntry)
        }
        
        try modelContext.save()
    }
    
    /// Get storage information (used, available)
    func getStorageInfo() -> (used: Int64, available: Int64) {
        let used = getTotalCacheSize()
        let available = getAvailableSpace()
        return (used, available)
    }
    
    // MARK: - Private Helpers
    
    private func canCache(_ audiobook: Audiobook) -> Bool {
        let available = getAvailableSpace()
        let required = audiobook.fileSize
        let current = getTotalCacheSize()
        
        // Check total cache size limit
        if current + required > maxCacheSizeWatch {
            return false
        }
        
        // Check book count limit
        let cachedCount = getCachedBooksCount()
        if cachedCount >= maxBooksWatch {
            return false
        }
        
        // Check actual disk space
        return available >= required
    }
    
    private func getTotalCacheSize() -> Int64 {
        let cacheURL = getCacheDirectory()
        return calculateDirectorySize(cacheURL)
    }
    
    private func getCachedBooksCount() -> Int {
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.isCached }
        )
        
        do {
            let books = try modelContext.fetch(descriptor)
            return books.count
        } catch {
            return 0
        }
    }
    
    private func getAvailableSpace() -> Int64 {
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(
                forPath: NSHomeDirectory()
            )
            
            if let freeSpace = systemAttributes[.systemFreeSize] as? NSNumber {
                return freeSpace.int64Value
            }
        } catch {
            print("Failed to get available space: \(error)")
        }
        
        return 0
    }
    
    private func getCacheDirectory() -> URL {
        let paths = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        
        let cacheDir = paths[0].appendingPathComponent("Audiobooks")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
        
        return cacheDir
    }
    
    private func calculateDirectorySize(_ url: URL) -> Int64 {
        var totalSize: Int64 = 0
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    private func runCleanup(requiredSpace: Int64) async throws {
        var freedSpace: Int64 = 0
        
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.isCached },
            sortBy: [SortDescriptor(\Audiobook.lastAccessedDate, order: .forward)]
        )
        
        let cachedBooks = try modelContext.fetch(descriptor)
        
        for book in cachedBooks {
            guard freedSpace < requiredSpace else { break }
            
            if shouldRemove(book) {
                try removeFromCache(book)
                freedSpace += book.fileSize
            }
        }
        
        if freedSpace < requiredSpace {
            throw AudiobookError.insufficientSpace
        }
    }
    
    private func shouldRemove(_ audiobook: Audiobook) -> Bool {
        let daysSinceAccess = Date().timeIntervalSince(audiobook.lastAccessedDate) / 86400
        
        // Never remove books accessed in last 7 days
        if daysSinceAccess < 7 {
            return false
        }
        
        // Remove books not accessed in 90 days
        if daysSinceAccess > 90 {
            return true
        }
        
        // Remove books not accessed in 30 days with low progress
        if daysSinceAccess > 30 {
            let progress = audiobook.playbackSession?.progressPercentage ?? 0
            if progress < 10 {
                return true
            }
        }
        
        return false
    }
    
    private func downloadFile(from url: URL, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        let (downloadURL, _) = try await URLSession.shared.download(from: url)
        return downloadURL
    }
}

// MARK: - Extended Errors

extension AudiobookError {
    static let invalidSource = AudiobookError.fileNotFound
}
