//
//  AudiobookCacheManager.swift
//  Listen This
//
//  Manages local audiobook cache across all devices
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

// MARK: - Concrete Implementation

/// Manages local audiobook cache files
@MainActor
final class AudiobookCacheManager: CacheManager {

    private let modelContext: ModelContext
    private let logger = AppLogger.cache

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

        // Get file size
        let fileSize =
            (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int64) ?? 0

        // Create or update cache entry
        if let existingEntry = audiobook.cacheEntry {
            // Update existing entry
            existingEntry.filePath = cacheURL.path
            existingEntry.fileSize = fileSize
            existingEntry.lastAccessedDate = Date()
            logger.debug("Updated existing cache entry for '\(audiobook.title)'")
        } else {
            // Create new cache entry
            let cacheEntry = CacheEntry(
                filePath: cacheURL.path,
                fileSize: fileSize,
                downloadedDate: Date(),
                lastAccessedDate: Date()
            )
            cacheEntry.audiobook = audiobook
            audiobook.cacheEntry = cacheEntry
            modelContext.insert(cacheEntry)
            logger.debug("Created new cache entry for '\(audiobook.title)'")
        }

        // Save the cache entry
        try modelContext.save()

        // Extract and update metadata from the cached M4B file
        Task {
            await extractAndUpdateMetadata(for: audiobook)
        }

        return cacheURL
    }

    /// Extract metadata from cached M4B file and update audiobook
    private func extractAndUpdateMetadata(for audiobook: Audiobook) async {
        do {
            logger.info("Extracting metadata from cached file for '\(audiobook.title)'")

            guard let fileURL = audiobook.cacheFileURL else {
                logger.info("Unable to extract metadata from cached file: no file URL provided")
                return
            }

            let metadata = try await MetadataExtractor.extractMetadata(from: fileURL)

            // Update audiobook with extracted metadata
            // Only update fields if they have values and are better than current data

            if let title = metadata.title, !title.isEmpty {
                audiobook.title = title
                logger.info("Updated title to: '\(title)'")
            }

            if let author = metadata.author, !author.isEmpty {
                audiobook.author = author
                logger.info("Updated author to: '\(author)'")
            }

            if let narrator = metadata.narrator, !narrator.isEmpty {
                audiobook.narrator = narrator
                logger.info("Updated narrator to: '\(narrator)'")
            }

            // Always update duration and chapter count from M4B file (more accurate)
            if metadata.duration > 0 {
                audiobook.duration = metadata.duration
                logger.info("Updated duration to: \(metadata.duration)s")
            }

            if metadata.chapterCount > 0 {
                audiobook.chapterCount = metadata.chapterCount
                logger.info("Updated chapter count to: \(metadata.chapterCount)")
            }

            // Update artwork if embedded artwork exists
            // This replaces the downscaled Audiobookshelf artwork with full quality
            if let artworkData = metadata.artworkData {
                let artworkSize = artworkData.count
                let currentArtworkSize = audiobook.artworkData?.count ?? 0

                audiobook.artworkData = artworkData
                logger.info(
                    "Updated artwork (\(ByteCountFormatter.string(fromByteCount: Int64(artworkSize), countStyle: .file)) vs previous \(ByteCountFormatter.string(fromByteCount: Int64(currentArtworkSize), countStyle: .file)))"
                )
            }

            // Save changes
            try modelContext.save()
            logger.info("Successfully updated metadata for '\(audiobook.title)'")

        } catch {
            logger.error(
                "Failed to extract metadata for '\(audiobook.title)': \(error.localizedDescription)"
            )
        }
    }

    /// Delete cached file for an audiobook
    func deleteCachedFile(for audiobook: Audiobook) throws {
        guard let cachePath = audiobook.expectedCachePath else {
            return
        }

        let cacheURL = URL(fileURLWithPath: cachePath)

        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            // Check if there's a file with UUID fallback name
            let uuidBasedPath = Self.cacheDirectory.appendingPathComponent(
                "\(audiobook.id.uuidString).m4b")
            if FileManager.default.fileExists(atPath: uuidBasedPath.path) {
                try FileManager.default.removeItem(at: uuidBasedPath)
            }

            // Clean up cache entry even if file doesn't exist
            if let cacheEntry = audiobook.cacheEntry {
                audiobook.cacheEntry = nil
                modelContext.delete(cacheEntry)
                try modelContext.save()
                logger.debug("Cleaned up stale cache entry for '\(audiobook.title)'")
            }

            return
        }

        // Delete the file
        try FileManager.default.removeItem(at: cacheURL)

        // Clean up cache entry
        if let cacheEntry = audiobook.cacheEntry {
            audiobook.cacheEntry = nil
            modelContext.delete(cacheEntry)
            try modelContext.save()
            logger.debug("Deleted cache entry for '\(audiobook.title)'")
        }
    }

    /// Removes cache for an audiobook with robust handling
    /// - Deletes file at stored path
    /// - Also deletes at expected cache path if different
    /// - Clears relationship BEFORE deleting entry (prevents SwiftData crashes)
    /// - Disables animations to prevent SwiftData issues
    func removeCache(for audiobook: Audiobook) throws {
        logger.info("[AudiobookCacheManager] Removing cache for: \(audiobook.title)")
        logger.info(
            "[AudiobookCacheManager] Expected cache path: \(audiobook.expectedCachePath ?? "nil")"
        )
        logger.info(
            "[AudiobookCacheManager] Cache entry path: \(audiobook.cacheEntry?.filePath ?? "nil")"
        )
        logger.info("[AudiobookCacheManager] isFileCached before: \(audiobook.isFileCached)")

        if let cacheEntry = audiobook.cacheEntry {
            // Delete file at the stored path
            let storedFileURL = URL(fileURLWithPath: cacheEntry.filePath)
            logger.info(
                "[AudiobookCacheManager] Attempting to delete file at: \(storedFileURL.path)"
            )
            do {
                try FileManager.default.removeItem(at: storedFileURL)
                logger.info(
                    "[AudiobookCacheManager] File deleted at stored path: \(storedFileURL.path)"
                )
            } catch {
                logger.warning(
                    "[AudiobookCacheManager] File deletion failed at stored path: \(error)"
                )
            }

            // ALSO delete file at expected cache path if different
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if expectedFileURL.path != storedFileURL.path {
                    logger.info(
                        "[AudiobookCacheManager] Paths differ! Also deleting at expected path: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        logger.info(
                            "[AudiobookCacheManager] File deleted at expected path: \(expectedPath)"
                        )
                    } catch {
                        logger.warning(
                            "[AudiobookCacheManager] File deletion failed at expected path: \(error)"
                        )
                    }
                }
            }

            // IMPORTANT: Clear the relationship BEFORE deleting the entry
            // This ensures SwiftData processes the changes in the correct order
            audiobook.cacheEntry = nil
            logger.info("[AudiobookCacheManager] Cache entry relationship cleared")

            // Remove cache entry
            modelContext.delete(cacheEntry)
            logger.info("[AudiobookCacheManager] Cache entry deleted from context")
        } else {
            logger.warning(
                "[AudiobookCacheManager] No cache entry found, but checking for orphaned file..."
            )
            // No cache entry but file might exist at expected path
            if let expectedPath = audiobook.expectedCachePath {
                let expectedFileURL = URL(fileURLWithPath: expectedPath)
                if FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    logger.info(
                        "[AudiobookCacheManager] Found orphaned file at expected path, deleting: \(expectedPath)"
                    )
                    do {
                        try FileManager.default.removeItem(at: expectedFileURL)
                        logger.info("[AudiobookCacheManager] Orphaned file deleted")
                    } catch {
                        logger.warning(
                            "[AudiobookCacheManager] Orphaned file deletion failed: \(error)"
                        )
                    }
                }
            }
        }

        // Save changes WITHOUT triggering List animations
        // Animation can cause SwiftData to have issues with the relationship updates
        var transaction = Transaction()
        transaction.disablesAnimations = true
        try withTransaction(transaction) {
            try modelContext.save()
            logger.info("[AudiobookCacheManager] Context saved successfully")
            logger.info(
                "[AudiobookCacheManager] Audiobook still in DB: id=\(audiobook.id), title=\(audiobook.title), cacheEntry=\(audiobook.cacheEntry == nil ? "nil" : "exists")"
            )
        }
    }

    /// Clean up CacheEntry if file doesn't exist
    /// This handles cases where the file was deleted externally but the database entry remains
    func cleanupStaleCacheEntry(for audiobook: Audiobook) {
        guard let cacheEntry = audiobook.cacheEntry else { return }

        // Verify file really doesn't exist
        let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        logger.warning(
            "[AudiobookCacheManager] Cleaning up stale CacheEntry for: \(audiobook.title)"
        )

        // Remove stale cache entry
        audiobook.cacheEntry = nil
        modelContext.delete(cacheEntry)

        do {
            try modelContext.save()
            logger.info("[AudiobookCacheManager] Stale cache entry removed")
        } catch {
            logger.error(
                "[AudiobookCacheManager] Failed to remove stale cache entry: \(error)"
            )
        }
    }

    /// Inverse of cleanupStaleCacheEntry: if a valid cache file exists at the
    /// expected path but there's no CacheEntry (e.g. it was downloaded by an
    /// older build that didn't record one), adopt the file by creating the
    /// entry. Heals pre-existing downloads on upgrade so they read as cached.
    /// Returns true if an entry was created.
    @discardableResult
    func adoptOrphanedCacheFileIfNeeded(for audiobook: Audiobook) -> Bool {
        guard audiobook.cacheEntry == nil,
            let cachePath = audiobook.expectedCachePath
        else { return false }

        let fileURL = URL(fileURLWithPath: cachePath)
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = (attrs[.size] as? NSNumber)?.int64Value,
            size > 0
        else { return false }

        // Only adopt a file that is actually the whole audiobook. A partial file
        // left behind by an interrupted transfer would otherwise be promoted to
        // "Downloaded", and playback would stop dead where the bytes end.
        // The 1% tolerance absorbs harmless drift between the server's reported
        // size and the bytes on disk without accepting a real truncation.
        if audiobook.fileSize > 0 {
            let minimumAcceptable = Int64(Double(audiobook.fileSize) * 0.99)
            guard size >= minimumAcceptable else {
                logger.warning(
                    "[AudiobookCacheManager] Not adopting partial file for '\(audiobook.title)': \(size) of \(audiobook.fileSize) bytes"
                )
                return false
            }
        }

        let entry = CacheEntry()
        entry.audiobook = audiobook
        audiobook.cacheEntry = entry
        entry.filePath = fileURL.path
        entry.fileSize = size
        entry.lastAccessedDate = Date()
        modelContext.insert(entry)

        do {
            try modelContext.save()
            logger.info("[AudiobookCacheManager] Adopted orphaned cache file for: \(audiobook.title)")
            return true
        } catch {
            logger.error(
                "[AudiobookCacheManager] Failed to adopt orphaned cache file: \(error)"
            )
            return false
        }
    }

    /// Get all cached audiobook files
    func getAllCachedFiles() -> [URL] {
        let cacheDir = Self.cacheDirectory

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
            )
        else {
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
                let size = attrs[.size] as? Int64
            {
                totalSize += size
            }
        }

        return totalSize
    }

    // MARK: - Orphan Cleanup

    /// Find and remove orphaned cache files (files without corresponding audiobook in database)
    /// This version fetches audiobooks from the database (protocol conformance)
    func cleanupOrphanedCaches() async throws {
        let descriptor = FetchDescriptor<Audiobook>()
        let audiobooks = try modelContext.fetch(descriptor)
        let _ = await cleanupOrphanedCaches(audiobooks: audiobooks)
    }

    /// Find and remove orphaned cache files (files without corresponding audiobook in database)
    /// This version accepts audiobooks as parameter (for use when already fetched)
    func cleanupOrphanedCaches(audiobooks: [Audiobook]) async -> (
        removedCount: Int, freedSpace: Int64
    ) {
        logger.info("[AudiobookCacheManager] Starting orphaned cache cleanup...")

        // Build a set of known filenames (for faster lookup)
        var knownFilenames = Set<String>()
        for audiobook in audiobooks {
            if let filename = audiobook.filename {
                knownFilenames.insert(filename)
            }
        }

        // Get cache directory
        let cacheDir = Self.cacheDirectory

        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            logger.info("[AudiobookCacheManager] No cache directory found, nothing to clean")
            return (0, 0)
        }

        // Get all cached files
        guard
            let cachedFiles = try? FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            logger.warning("[AudiobookCacheManager] Failed to read cache directory")
            return (0, 0)
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
                        atPath: fileURL.path
                    )[.size] as? Int64 {
                        freedSpace += fileSize
                    }

                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                    logger.info("[AudiobookCacheManager] Removed orphaned cache: \(filename)")
                } catch {
                    logger.warning(
                        "[AudiobookCacheManager] Failed to remove orphaned cache \(filename): \(error)"
                    )
                }
            }
        }

        if removedCount > 0 {
            let freedSpaceMB = Double(freedSpace) / 1_000_000.0
            logger.info(
                "[AudiobookCacheManager] Cleanup complete: removed \(removedCount) orphaned cache(s), freed \(String(format: "%.1f", freedSpaceMB)) MB"
            )
        } else {
            logger.info("[AudiobookCacheManager] No orphaned caches found")
        }

        return (removedCount, freedSpace)
    }

    /// Clean up old cached files to free space
    /// Uses CacheSettings.shared.keepRecentCount if no count is specified
    func evictOldCaches(keepingCount: Int? = nil) async throws {
        let count = keepingCount ?? CacheSettings.shared.keepRecentCount
        // Get all audiobooks with cached files
        let descriptor = FetchDescriptor<Audiobook>(
            sortBy: [SortDescriptor(\.lastAccessedDate, order: .reverse)]
        )
        let audiobooks = try modelContext.fetch(descriptor)

        // Find cached audiobooks
        let cachedAudiobooks = audiobooks.filter { $0.isFileCached }

        // Keep only the most recent
        if cachedAudiobooks.count > count {
            let toDelete = cachedAudiobooks.dropFirst(count)
            var freedSpace: Int64 = 0

            for audiobook in toDelete {
                guard let cachePath = audiobook.expectedCachePath else {
                    continue
                }

                let cacheURL = URL(fileURLWithPath: cachePath)

                if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                    let size = attrs[.size] as? Int64
                {
                    freedSpace += size
                }

                try FileManager.default.removeItem(at: cacheURL)
            }
        }
    }

    /// Check if cache is over a certain size and clean up if needed
    /// Uses CacheSettings.shared.maxCacheSizeBytes if no size is specified
    /// Evicts oldest files while respecting keepRecentCount minimum
    func cleanupIfNeeded(maxSize: Int64? = nil) async throws {
        // Only run if auto cleanup is enabled
        guard CacheSettings.shared.autoCleanupEnabled else { return }

        let limit = maxSize ?? CacheSettings.shared.maxCacheSizeBytes
        let currentSize = getCacheSize()

        // If under limit, nothing to do
        if currentSize <= limit {
            return
        }

        // Get all audiobooks sorted by last access (oldest first for eviction)
        let descriptor = FetchDescriptor<Audiobook>(
            sortBy: [SortDescriptor(\.lastAccessedDate, order: .reverse)]
        )
        let audiobooks = try modelContext.fetch(descriptor)

        // Find cached audiobooks (most recent first due to sort order)
        let cachedAudiobooks = audiobooks.filter { $0.isFileCached }

        let keepRecentCount = CacheSettings.shared.keepRecentCount

        // Evict oldest files until under limit, but keep at least keepRecentCount files
        var freedSpace: Int64 = 0
        var deletedCount = 0

        // Start from the oldest (end of array) and work backwards
        for audiobook in cachedAudiobooks.reversed() {
            // Stop if we're under the limit
            if currentSize - freedSpace <= limit {
                break
            }

            // Protect the most recent N audiobooks
            let remainingCount = cachedAudiobooks.count - deletedCount
            if remainingCount <= keepRecentCount {
                // Can't delete any more without violating keepRecentCount
                break
            }

            // Delete this cached file
            guard let cachePath = audiobook.expectedCachePath else {
                continue
            }

            let cacheURL = URL(fileURLWithPath: cachePath)

            if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
                let size = attrs[.size] as? Int64
            {
                try FileManager.default.removeItem(at: cacheURL)
                freedSpace += size
                deletedCount += 1
                logger.info(
                    "Evicted '\(audiobook.title)' (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) to free space"
                )
            }
        }

        if deletedCount > 0 {
            logger.info(
                "Cleanup freed \(ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file)) by removing \(deletedCount) file(s)"
            )
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

        guard
            let ubiquityURL = FileManager.default.url(
                forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
            )
        else {
            throw AudiobookError.cloudKitUnavailable
        }

        let iCloudURL = ubiquityURL.appendingPathComponent(iCloudPath)

        // Trigger download if needed
        if !FileManager.default.fileExists(atPath: iCloudURL.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: iCloudURL)

            // Wait for download (simplified - production should have progress tracking)
            for _ in 0..<300 {  // 5 minutes timeout
                try await Task.sleep(nanoseconds: 1_000_000_000)

                let status = try? iCloudURL.resourceValues(forKeys: [
                    .ubiquitousItemDownloadingStatusKey
                ])
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
// MARK: - Mock Implementation (Previews & Testing)
