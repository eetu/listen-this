//
//  PreviewAudiobookCacheManager.swift
//  Listen This
//
//  Created by Eetu Sutinen on 23.12.2025.
//

import Foundation
import SwiftData

@MainActor
final class PreviewAudiobookCacheManager: CacheManager {
    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MockAudiobooks")
    }
    
    var cachedFiles: [URL] = []
    var totalCacheSize: Int64 = 0
    private var fileCache: [String: URL] = [:]
    
    func cacheAudiobook(_ audiobook: Audiobook, from sourceURL: URL) throws -> URL {
        let cacheURL = Self.cacheDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        cachedFiles.append(cacheURL)
        fileCache[audiobook.id.uuidString] = cacheURL
        
        // Mock file size
        totalCacheSize += 100_000_000
        
        return cacheURL
    }
    
    func deleteCachedFile(for audiobook: Audiobook) throws {
        if let url = fileCache[audiobook.id.uuidString],
           let index = cachedFiles.firstIndex(of: url) {
            cachedFiles.remove(at: index)
            fileCache.removeValue(forKey: audiobook.id.uuidString)
            totalCacheSize = max(0, totalCacheSize - 100_000_000)
        }
    }
    
    func getAllCachedFiles() -> [URL] {
        return cachedFiles
    }
    
    func getCacheSize() -> Int64 {
        return totalCacheSize
    }
    
    func cleanupOrphanedCaches() async throws {
        // Mock: cleaned up orphans
        if cachedFiles.count > 0 {
            cachedFiles.removeFirst()
            totalCacheSize = max(0, totalCacheSize - 100_000_000)
        }
    }
    
    func evictOldCaches(keepingCount: Int = 5) async throws {
        if cachedFiles.count > keepingCount {
            let toRemove = cachedFiles.count - keepingCount
            cachedFiles.removeLast(toRemove)
            totalCacheSize = max(0, totalCacheSize - (Int64(toRemove) * 100_000_000))
        }
    }
    
    func cleanupIfNeeded(maxSize: Int64 = 3_000_000_000) async throws {
        if totalCacheSize > maxSize {
            try await evictOldCaches(keepingCount: 3)
        }
    }
}


