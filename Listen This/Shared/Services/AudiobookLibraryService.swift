//
//  AudiobookLibraryService.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation
import SwiftData
import SwiftUI

/// Service for managing audiobook library across different content sources
@MainActor
@Observable
final class AudiobookLibraryService {

    // MARK: - Properties

    private let modelContext: ModelContext
    private let iCloudProvider = iCloudDriveProvider()
    private let cacheManager: AudiobookCacheManager

    var isRefreshing = false
    var lastError: AudiobookError?

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.cacheManager = AudiobookCacheManager(modelContext: modelContext)
    }

    // MARK: - File Import

    /// Import an M4B file from document picker or other source
    func importFile(from url: URL) async throws -> Audiobook {
        // Start accessing security-scoped resource
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 1. Copy file to iCloud Drive
        let iCloudRelativePath = try await copyToICloudDrive(from: url)

        // 2. Extract metadata from original file
        let metadata = try await extractMetadataFromFile(url)

        // 3. Extract artwork
        var artworkData: Data?
        do {
            artworkData = try await extractArtworkFromFile(url)
        } catch {
            // No artwork available
        }

        // 4. Create audiobook with iCloud path
        let audiobook = Audiobook(
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            artworkData: artworkData,
            duration: metadata.duration,
            fileSize: metadata.fileSize,
            iCloudRelativePath: iCloudRelativePath,
            chapterCount: metadata.chapterCount
        )

        // 5. Extract and create chapters
        do {
            let chapterInfos = try await extractChaptersFromFile(url)

            // Initialize chapters array if needed
            if audiobook.chapters == nil {
                audiobook.chapters = []
            }

            for chapterInfo in chapterInfos {
                let chapter = Chapter(
                    index: chapterInfo.index,
                    title: chapterInfo.title,
                    startTime: chapterInfo.startTime,
                    duration: chapterInfo.duration
                )

                // Set the relationship
                chapter.audiobook = audiobook

                // Insert into context
                modelContext.insert(chapter)

                // Append to audiobook's chapters array
                audiobook.chapters?.append(chapter)
            }
        } catch {
            // Chapter extraction failed, continue without chapters
        }

        // 6. Create initial playback session
        let session = PlaybackSession()
        audiobook.playbackSession = session

        // 7. Cache locally on iPhone for immediate playback
        _ = try cacheManager.cacheAudiobook(audiobook, from: url)

        // 8. Save to SwiftData (will sync via CloudKit to Watch)
        modelContext.insert(audiobook)
        try modelContext.save()

        // 9. Cleanup old caches if needed
        try await cacheManager.cleanupIfNeeded()

        return audiobook
    }

    // MARK: - Private Helper Methods

    /// Copy file to iCloud Drive and return the relative path
    private func copyToICloudDrive(from sourceURL: URL) async throws -> String {
        guard let ubiquityURL = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
        ) else {
            throw AudiobookError.cloudKitUnavailable
        }

        let audiobooksDir = ubiquityURL.appendingPathComponent("Documents/Audiobooks")
        try FileManager.default.createDirectory(at: audiobooksDir, withIntermediateDirectories: true)

        let fileName = sourceURL.lastPathComponent
        let destinationURL = audiobooksDir.appendingPathComponent(fileName)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            // Use unique name to avoid conflicts
            let uniqueName = "\(UUID().uuidString)_\(fileName)"
            let uniqueDestinationURL = audiobooksDir.appendingPathComponent(uniqueName)
            try FileManager.default.copyItem(at: sourceURL, to: uniqueDestinationURL)
            return "Documents/Audiobooks/\(uniqueName)"
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return "Documents/Audiobooks/\(fileName)"
        }
    }

    /// Cache file locally for offline playback
    private func cacheLocally(from sourceURL: URL, audiobook: Audiobook) async throws -> String {
        _ = try cacheManager.cacheAudiobook(audiobook, from: sourceURL)

        guard let cachePath = audiobook.expectedCachePath else {
            throw AudiobookError.fileNotFound
        }

        return cachePath
    }

    /// Extract metadata from an M4B file
    private func extractMetadataFromFile(_ url: URL) async throws -> (
        title: String,
        author: String,
        narrator: String?,
        duration: Double,
        fileSize: Int64,
        chapterCount: Int
    ) {
        // Delegate to iCloudProvider for actual extraction
        let metadata = try await iCloudProvider.getAudiobookMetadata(identifier: url.absoluteString)
        return (
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            duration: metadata.duration,
            fileSize: metadata.fileSize,
            chapterCount: metadata.chapterCount
        )
    }

    /// Extract artwork from an M4B file
    private func extractArtworkFromFile(_ url: URL) async throws -> Data {
        return try await iCloudProvider.getArtwork(identifier: url.absoluteString)
    }

    /// Extract chapters from an M4B file
    private func extractChaptersFromFile(_ url: URL) async throws -> [ChapterInfo] {
        return try await iCloudProvider.extractChapters(from: url)
    }

    // MARK: - Library Refresh

    /// Scan iCloud Drive for new M4B files and import them
    func refreshLibrary() async {
        isRefreshing = true
        lastError = nil

        defer {
            isRefreshing = false
        }

        do {
            // 1. Fetch all M4B files from iCloud Drive
            let metadataList = try await iCloudProvider.fetchLibrary()

            // 2. Get existing audiobooks from database
            let descriptor = FetchDescriptor<Audiobook>()
            let existingAudiobooks = try modelContext.fetch(descriptor)
            let existingPaths = Set(existingAudiobooks.compactMap { $0.iCloudRelativePath })

            // 3. Import new files that aren't already in the library
            for metadata in metadataList {
                // Convert absolute URL to relative path for comparison
                guard let url = URL(string: metadata.identifier),
                      let ubiquityURL = FileManager.default.url(
                        forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
                      ) else {
                    continue
                }

                let relativePath = url.path.replacingOccurrences(
                    of: ubiquityURL.path + "/",
                    with: ""
                )

                // Skip if already imported
                if existingPaths.contains(relativePath) {
                    continue
                }

                // Import the new file
                do {
                    _ = try await importFile(from: url)
                } catch {
                    // Failed to import this file, continue with others
                }
            }

        } catch {
            lastError = error as? AudiobookError ?? .unknown(error)
        }
    }

    // MARK: - Search

    /// Search audiobooks by query
    func searchAudiobooks(query: String) -> [Audiobook] {
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { audiobook in
                audiobook.title.localizedStandardContains(query) ||
                audiobook.author.localizedStandardContains(query)
            }
        )

        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Deletion

    /// Delete an audiobook and its associated files from all locations
    /// - Parameter audiobook: The audiobook to delete
    /// - Parameter deleteFromiCloud: Whether to delete the file from iCloud Drive (default: true)
    /// - Note: CloudKit will automatically sync the deletion to Watch and other devices
    func deleteAudiobook(
        _ audiobook: Audiobook,
        deleteFromiCloud: Bool = true
    ) async throws {
        // IMPORTANT: Force load external storage attributes before deletion
        // This resolves the fault so SwiftData can properly clean up external storage
        _ = audiobook.artworkData

        var errors: [Error] = []

        // 1. Delete local cache
        do {
            try cacheManager.deleteCachedFile(for: audiobook)
        } catch {
            errors.append(error)
            // Continue - not a fatal error
        }

        // 2. Delete from iCloud Drive if requested
        if deleteFromiCloud, let iCloudPath = audiobook.iCloudRelativePath {
            if let ubiquityURL = FileManager.default.url(
                forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
            ) {
                let iCloudFileURL = ubiquityURL.appendingPathComponent(iCloudPath)

                // Use NSFileCoordinator for iCloud files
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var deleteError: Error?

                coordinator.coordinate(writingItemAt: iCloudFileURL, options: .forDeleting, error: &coordinationError) { url in
                    do {
                        // Check if file exists first
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                    } catch {
                        deleteError = error
                    }
                }

                if let error = coordinationError {
                    errors.append(error)
                }
                if let error = deleteError {
                    errors.append(error)
                }
            } else {
                let error = AudiobookError.cloudKitUnavailable
                errors.append(error)
            }
        }

        // 3. Delete from SwiftData (will sync deletion via CloudKit to Watch)
        modelContext.delete(audiobook)

        do {
            try modelContext.save()
        } catch {
            throw error  // This is a fatal error
        }

        // Don't throw for non-fatal errors - deletion from database succeeded which is most important
    }

    // MARK: - Cache Management

    /// Clean up orphaned caches (files without audiobook records)
    func cleanupOrphanedCaches() async throws {
        try await cacheManager.cleanupOrphanedCaches()
    }

    /// Get current cache size
    func getCacheSize() -> Int64 {
        return cacheManager.getCacheSize()
    }
}
