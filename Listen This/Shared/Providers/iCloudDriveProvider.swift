//
//  iCloudDriveProvider.swift
//  listen this
//

import AVFoundation
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Content provider for accessing M4B audiobooks from iCloud Drive
@MainActor
final class iCloudDriveProvider: ContentSource {

    // MARK: - Properties

    /// The ubiquity container URL for iCloud Drive access
    private var ubiquityURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This")
    }

    /// Documents directory in iCloud Drive
    private var documentsURL: URL? {
        ubiquityURL?.appendingPathComponent("Documents")
    }

    /// Flag to check if iCloud Drive is available
    var isAvailable: Bool {
        ubiquityURL != nil
    }

    // MARK: - Authentication

    func authenticate(credentials: Credentials) async throws {
        // iCloud Drive doesn't require credentials
        // Just verify availability
        try validateDocumentsDirectory()
    }

    func validateAccess() async throws -> Bool {
        // Check if ubiquity container is available with specific container ID
        let _ = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This")

        guard isAvailable else {
            AppLogger.iCloudDrive.warning(
                "iCloud Drive is NOT available - Enable iCloud Documents capability in Xcode")
            return false
        }

        guard let docsURL = documentsURL else {
            AppLogger.iCloudDrive.warning("iCloud Documents URL is nil")
            return false
        }

        // Ensure the documents directory exists
        do {
            try ensureDocumentsDirectoryExists()
        } catch {
            AppLogger.iCloudDrive.error(
                "Failed to create documents directory: \(error.localizedDescription)")
            throw error
        }

        let exists = FileManager.default.fileExists(atPath: docsURL.path)

        return exists
    }

    // MARK: - Library Management

    func fetchLibrary() async throws -> [AudiobookMetadata] {
        let docsURL = try validateDocumentsDirectory()

        let fileURLs = try await scanForM4BFiles(in: docsURL)

        var metadataList: [AudiobookMetadata] = []

        for fileURL in fileURLs {
            do {
                let metadata = try await extractMetadata(from: fileURL)
                metadataList.append(metadata)
            } catch {
                AppLogger.iCloudDrive.error(
                    "Failed to extract metadata from \(fileURL.lastPathComponent): \(error.localizedDescription)"
                )
                // Continue with other files
            }
        }

        return metadataList
    }

    func getAudiobookMetadata(identifier: String) async throws -> AudiobookMetadata {
        let url = try validateFileURL(identifier)
        return try await extractMetadata(from: url)
    }

    func searchLibrary(query: String) async throws -> [AudiobookMetadata] {
        let allBooks = try await fetchLibrary()
        let lowercaseQuery = query.lowercased()

        return allBooks.filter { metadata in
            metadata.title.lowercased().contains(lowercaseQuery)
                || metadata.author.lowercased().contains(lowercaseQuery)
                || (metadata.narrator?.lowercased().contains(lowercaseQuery) ?? false)
        }
    }

    // MARK: - Content Access

    func getStreamURL(identifier: String) async throws -> URL {
        return try validateFileURL(identifier, checkExists: true)
    }

    func getDownloadURL(identifier: String) async throws -> URL {
        // iCloud Drive files are already local (or auto-download)
        return try await getStreamURL(identifier: identifier)
    }

    func getArtwork(identifier: String) async throws -> Data {
        let url = try validateFileURL(identifier)
        return try await extractArtwork(from: url)
    }

    // MARK: - Progress Sync (Not Applicable)

    func syncProgress(identifier: String, position: Double) async throws {
        // iCloud Drive provider doesn't sync progress to server
        // Progress will be handled by CloudKit sync later
    }

    func getProgress(identifier: String) async throws -> Double? {
        // No server-side progress for iCloud Drive
        return nil
    }

    // MARK: - File Scanning

    /// Recursively scan for M4B files in a directory
    private func scanForM4BFiles(in directory: URL) async throws -> [URL] {
        // Use nonisolated context for FileManager operations
        let fileURLs = await Task.detached {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else {
                return [URL]()
            }

            var urls: [URL] = []
            // Convert to array first to avoid iterator issues in async context
            let allItems = enumerator.allObjects
            for case let fileURL as URL in allItems {
                // Check if it's a regular file
                guard
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                    let isRegularFile = resourceValues.isRegularFile,
                    isRegularFile
                else {
                    continue
                }

                // Check for M4B extension
                if fileURL.pathExtension.lowercased() == "m4b" {
                    urls.append(fileURL)
                }
            }
            return urls
        }.value

        return fileURLs
    }

    // MARK: - Metadata Extraction

    /// Extract metadata from an M4B file using AVAsset
    private func extractMetadata(from url: URL) async throws -> AudiobookMetadata {
        // Use shared MetadataExtractor
        let extractedMetadata = try await MetadataExtractor.extractMetadata(from: url)

        // Get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0

        // Get creation date
        let creationDate = fileAttributes[.creationDate] as? Date ?? Date()

        return AudiobookMetadata(
            identifier: url.absoluteString,
            title: extractedMetadata.title ?? url.deletingPathExtension().lastPathComponent,
            author: extractedMetadata.author ?? "Unknown Author",
            narrator: extractedMetadata.narrator,
            duration: extractedMetadata.duration,
            fileSize: fileSize,
            sourceType: "icloud",
            sourceURL: url.absoluteString,
            chapterCount: extractedMetadata.chapterCount,
            addedDate: creationDate,
            artworkURL: nil
        )
    }

    /// Extract artwork data from an M4B file
    private func extractArtwork(from url: URL) async throws -> Data {
        // Use shared MetadataExtractor
        guard let artworkData = try await MetadataExtractor.extractArtwork(from: url) else {
            throw AudiobookError.fileNotFound
        }
        return artworkData
    }

    // MARK: - Chapter Extraction

    /// Extract chapter information from an M4B file
    func extractChapters(from url: URL) async throws -> [ChapterInfo] {
        // Use shared MetadataExtractor
        let extractedChapters = try await MetadataExtractor.extractChapters(from: url)

        // Convert ExtractedChapter to ChapterInfo
        return extractedChapters.map { chapter in
            ChapterInfo(
                index: chapter.index,
                title: chapter.title,
                startTime: chapter.startTime,
                duration: chapter.duration
            )
        }
    }

    // MARK: - File Import

    /// Import an M4B file from outside iCloud Drive into the app's container
    func importFile(from sourceURL: URL) async throws -> URL {
        let docsURL = try validateDocumentsDirectory()

        let fileName = sourceURL.lastPathComponent
        let destinationURL = docsURL.appendingPathComponent(fileName)

        // Check if file already exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            // Generate unique name
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let uniqueName = "\(baseName)_\(UUID().uuidString).\(ext)"
            let uniqueURL = docsURL.appendingPathComponent(uniqueName)

            try FileManager.default.copyItem(at: sourceURL, to: uniqueURL)
            return uniqueURL
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }
    }

    // MARK: - Helper Methods

    /// Validates and ensures the documents directory exists
    @discardableResult
    private func validateDocumentsDirectory() throws -> URL {
        guard isAvailable else {
            throw AudiobookError.cloudKitUnavailable
        }

        guard let docsURL = documentsURL else {
            throw AudiobookError.cloudKitUnavailable
        }

        try ensureDocumentsDirectoryExists()
        return docsURL
    }

    /// Ensures the documents directory exists
    private func ensureDocumentsDirectoryExists() throws {
        guard let docsURL = documentsURL else {
            throw AudiobookError.cloudKitUnavailable
        }

        try FileManager.default.createDirectory(
            at: docsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Validates a file URL from an identifier string
    private func validateFileURL(_ identifier: String, checkExists: Bool = false) throws -> URL {
        guard let url = URL(string: identifier) else {
            throw AudiobookError.fileNotFound
        }

        if checkExists && !FileManager.default.fileExists(atPath: url.path) {
            throw AudiobookError.fileNotFound
        }

        return url
    }
}

// MARK: - Supporting Types

/// Chapter information extracted from M4B file
struct ChapterInfo {
    let index: Int
    let title: String
    let startTime: Double
    let duration: Double
}
