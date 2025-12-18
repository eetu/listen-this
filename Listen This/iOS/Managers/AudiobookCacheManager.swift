//
//  AudiobookCacheManager.swift
//  Listen This
//
//  Manages local audiobook cache across all devices
//

import Foundation
import SwiftData

/// Manages local audiobook cache files
@MainActor
final class AudiobookCacheManager {
    
    private let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Cache Directory
    
    /// Get the cache directory for audiobooks
    static var cacheDirectory: URL {
        let cacheDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")
        
        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
        
        return cacheDir
    }
    
    // MARK: - Cache Management
    
    /// Cache an audiobook file locally
    func cacheAudiobook(_ audiobook: Audiobook, from sourceURL: URL) throws -> URL {
        // Use the original filename from the source
        let originalFilename = sourceURL.lastPathComponent
        let cacheURL = Self.cacheDirectory.appendingPathComponent(originalFilename)
        
        // Remove existing cached file
        try? FileManager.default.removeItem(at: cacheURL)
        
        // Copy to cache
        try FileManager.default.copyItem(at: sourceURL, to: cacheURL)
        
        print("💾 [Cache] Cached audiobook: \(audiobook.title)")
        print("   Filename: \(originalFilename)")
        print("   Path: \(cacheURL.path)")
        
        return cacheURL
    }
    
    /// Delete cached file for an audiobook
    func deleteCachedFile(for audiobook: Audiobook) throws {
        guard let cachePath = audiobook.expectedCachePath else {
            print("ℹ️ [Cache] No cache path available for: \(audiobook.title)")
            return
        }
        
        let cacheURL = URL(fileURLWithPath: cachePath)
        
        print("🗑️ [Cache] Attempting to delete cache for: \(audiobook.title)")
        print("   Cache path: \(cacheURL.path)")
        if let filename = audiobook.filename {
            print("   Filename: \(filename)")
        }
        
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            print("ℹ️ [Cache] No cache file to delete (file doesn't exist)")
            
            // Check if there's a file with UUID fallback name
            let uuidBasedPath = Self.cacheDirectory.appendingPathComponent("\(audiobook.id.uuidString).m4b")
            if FileManager.default.fileExists(atPath: uuidBasedPath.path) {
                print("ℹ️ [Cache] Found file with UUID-based name, deleting that instead")
                try FileManager.default.removeItem(at: uuidBasedPath)
                print("🗑️ [Cache] Deleted UUID-based cache file")
                return
            }
            
            return
        }
        
        try FileManager.default.removeItem(at: cacheURL)
        print("✅ [Cache] Successfully deleted cache file")
    }
    
    /// Get all cached audiobook files
    func getAllCachedFiles() -> [URL] {
        let cacheDir = Self.cacheDirectory
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else {
            return []
        }
        
        return files.filter { $0.pathExtension == "m4b" }
    }
    
    /// Get total size of cached audiobooks
    func getCacheSize() -> Int64 {
        let cachedFiles = getAllCachedFiles()
        
        var totalSize: Int64 = 0
        for file in cachedFiles {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }
        
        return totalSize
    }
    
    // MARK: - Orphan Cleanup
    
    /// Find and remove orphaned cache files (files without corresponding audiobook in database)
    func cleanupOrphanedCaches() async throws {
        print("🧹 [Cache] Starting orphaned cache cleanup...")
        
        // Get all cached files
        let cachedFiles = getAllCachedFiles()
        print("🧹 [Cache] Found \(cachedFiles.count) cached file(s)")
        
        // Get all audiobook filenames from database
        let descriptor = FetchDescriptor<Audiobook>()
        let audiobooks = try modelContext.fetch(descriptor)
        
        // Build a set of known filenames (for faster lookup)
        var knownFilenames = Set<String>()
        for audiobook in audiobooks {
            // Get the filename from the audiobook's source path
            if let iCloudPath = audiobook.iCloudRelativePath {
                let filename = URL(fileURLWithPath: iCloudPath).lastPathComponent
                knownFilenames.insert(filename)
            }
            // Also check if there's a localFilename property
            if let localFilename = audiobook.localFilename {
                knownFilenames.insert(localFilename)
            }
        }
        
        print("🧹 [Cache] Found \(audiobooks.count) audiobook(s) in database")
        print("🧹 [Cache] Known filenames: \(knownFilenames.count)")
        
        // Check each cached file
        var orphanedCount = 0
        var freedSpace: Int64 = 0
        
        for fileURL in cachedFiles {
            let filename = fileURL.lastPathComponent
            
            // Check if this filename belongs to any audiobook
            if !knownFilenames.contains(filename) {
                // Orphaned cache file - delete it
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[FileAttributeKey.size] as? Int64 {
                    freedSpace += size
                }
                
                try FileManager.default.removeItem(at: fileURL)
                orphanedCount += 1
                print("🗑️ [Cache] Deleted orphaned cache: \(filename)")
            }
        }
        
        if orphanedCount > 0 {
            let sizeString = ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file)
            print("✅ [Cache] Cleanup complete!")
            print("   Removed: \(orphanedCount) orphaned file(s)")
            print("   Freed: \(sizeString)")
        } else {
            print("✅ [Cache] No orphaned caches found")
        }
    }
    
    /// Clean up old cached files to free space
    func evictOldCaches(keepingCount: Int = 5) async throws {
        print("🧹 [Cache] Evicting old caches (keeping \(keepingCount) most recent)...")
        
        // Get all audiobooks with cached files
        let descriptor = FetchDescriptor<Audiobook>(
            sortBy: [SortDescriptor(\.lastAccessedDate, order: .reverse)]
        )
        let audiobooks = try modelContext.fetch(descriptor)
        
        // Find cached audiobooks
        let cachedAudiobooks = audiobooks.filter { $0.isFileCached }
        print("🧹 [Cache] Found \(cachedAudiobooks.count) cached audiobook(s)")
        
        // Keep only the most recent
        if cachedAudiobooks.count > keepingCount {
            let toDelete = cachedAudiobooks.dropFirst(keepingCount)
            var freedSpace: Int64 = 0
            
            for audiobook in toDelete {
                guard let cachePath = audiobook.expectedCachePath else {
                    continue
                }
                
                let cacheURL = URL(fileURLWithPath: cachePath)
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                   let size = attrs[.size] as? Int64 {
                    freedSpace += size
                }
                
                try FileManager.default.removeItem(at: cacheURL)
                print("🗑️ [Cache] Evicted: \(audiobook.title)")
            }
            
            let sizeString = ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file)
            print("✅ [Cache] Eviction complete!")
            print("   Removed: \(toDelete.count) old cache(s)")
            print("   Freed: \(sizeString)")
        } else {
            print("✅ [Cache] No eviction needed")
        }
    }
    
    /// Check if cache is over a certain size and clean up if needed
    func cleanupIfNeeded(maxSize: Int64 = 3_000_000_000) async throws {  // 3GB default
        let currentSize = getCacheSize()
        
        print("📊 [Cache] Current size: \(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))")
        
        if currentSize > maxSize {
            print("⚠️ [Cache] Cache size exceeds limit, cleaning up...")
            try await evictOldCaches(keepingCount: 3)
        }
    }
}

// MARK: - Convenience Extensions

extension Audiobook {
    
    /// Cache this audiobook from iCloud Drive
    @MainActor
    func downloadAndCache(using cacheManager: AudiobookCacheManager) async throws -> URL {
        guard let iCloudPath = iCloudRelativePath else {
            throw AudiobookError.fileNotFound
        }
        
        guard let ubiquityURL = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
        ) else {
            throw AudiobookError.cloudKitUnavailable
        }
        
        let iCloudURL = ubiquityURL.appendingPathComponent(iCloudPath)
        
        // Trigger download if needed
        if !FileManager.default.fileExists(atPath: iCloudURL.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: iCloudURL)
            
            // Wait for download (simplified - production should have progress tracking)
            for _ in 0..<300 {  // 5 minutes timeout
                try await Task.sleep(nanoseconds: 1_000_000_000)
                
                let status = try? iCloudURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if status?.ubiquitousItemDownloadingStatus == .current {
                    break
                }
            }
        }
        
        // Cache the file
        return try cacheManager.cacheAudiobook(self, from: iCloudURL)
    }
    
    /// Delete local cache for this audiobook
    @MainActor
    func deleteCache(using cacheManager: AudiobookCacheManager) throws {
        try cacheManager.deleteCachedFile(for: self)
    }
}
