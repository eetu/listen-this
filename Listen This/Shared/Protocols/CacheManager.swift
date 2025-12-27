//
//  CacheManager.swift
//  Listen This
//
//  Protocol for cache management operations
//

import Foundation

/// Protocol for managing local audiobook cache
@MainActor
protocol CacheManager: AnyObject {
    static var cacheDirectory: URL { get }

    func cacheAudiobook(_ audiobook: Audiobook, from sourceURL: URL) throws -> URL
    func deleteCachedFile(for audiobook: Audiobook) throws
    func getAllCachedFiles() -> [URL]
    func getCacheSize() -> Int64
    func cleanupOrphanedCaches() async throws
    func evictOldCaches(keepingCount: Int?) async throws
    func cleanupIfNeeded(maxSize: Int64?) async throws
}
