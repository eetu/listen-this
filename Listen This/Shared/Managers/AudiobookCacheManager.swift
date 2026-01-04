//
//  AudiobookCacheManager.swift
//  Listen This
//
//  Manages local audiobook cache across all devices
//

import Foundation
import OSLog
import SwiftData

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

        // Extract and update metadata from the cached M4B file
        Task {
            await extractAndUpdateMetadata(for: audiobook, from: cacheURL)
        }

        return cacheURL
    }

    /// Extract metadata from cached M4B file and update audiobook
    private func extractAndUpdateMetadata(for audiobook: Audiobook, from fileURL: URL) async {
        do {
            logger.info("Extracting metadata from cached file for '\(audiobook.title)'")

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

                // Only update if new artwork is larger (better quality)
                if artworkSize > currentArtworkSize {
                    audiobook.artworkData = artworkData
                    logger.info(
                        "Updated artwork (\(ByteCountFormatter.string(fromByteCount: Int64(artworkSize), countStyle: .file)) vs previous \(ByteCountFormatter.string(fromByteCount: Int64(currentArtworkSize), countStyle: .file)))"
                    )
                } else {
                    logger.info("Keeping existing artwork (larger than embedded)")
                }
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
                return
            }

            return
        }

        try FileManager.default.removeItem(at: cacheURL)
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
    func cleanupOrphanedCaches() async throws {
        // Get all cached files
        let cachedFiles = getAllCachedFiles()

        // Get all audiobook filenames from database
        let descriptor = FetchDescriptor<Audiobook>()
        let audiobooks = try modelContext.fetch(descriptor)

        // Build a set of known filenames (for faster lookup)
        var knownFilenames = Set<String>()
        for audiobook in audiobooks {
            if let filename = audiobook.filename {
                knownFilenames.insert(filename)
            }
        }

        // Check each cached file
        var orphanedCount = 0
        var freedSpace: Int64 = 0

        for fileURL in cachedFiles {
            let filename = fileURL.lastPathComponent

            // Check if this filename belongs to any audiobook
            if !knownFilenames.contains(filename) {
                // Orphaned cache file - delete it
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                    let size = attrs[FileAttributeKey.size] as? Int64
                {
                    freedSpace += size
                }

                try FileManager.default.removeItem(at: fileURL)
                orphanedCount += 1
            }
        }
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
