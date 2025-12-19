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
        print("🔧 Starting file import from: \(url.lastPathComponent)")
        
        // Start accessing security-scoped resource
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
                print("   🔓 Released security-scoped resource")
            }
        }
        
        // 1. Copy file to iCloud Drive
        print("   📋 Copying to iCloud Drive...")
        let iCloudRelativePath = try await copyToICloudDrive(from: url)
        print("   ✅ Copied to iCloud Drive: \(iCloudRelativePath)")
        
        // 2. Extract metadata from original file
        print("   🔍 Extracting metadata...")
        let metadata = try await extractMetadataFromFile(url)
        print("   ✅ Metadata extracted: \(metadata.title)")
        
        // 3. Extract artwork
        var artworkData: Data?
        do {
            artworkData = try await extractArtworkFromFile(url)
            print("   🖼️ Artwork extracted")
        } catch {
            print("   ⚠️ No artwork available")
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
            localFilename: url.lastPathComponent,  // Store the actual filename
            chapterCount: metadata.chapterCount
        )
        
        print("   🎯 Audiobook object created")
        print("      ID: \(audiobook.id)")
        print("      Title: \(audiobook.title)")
        print("      iCloud Path: \(iCloudRelativePath)")
        
        // 5. Extract and create chapters
        do {
            let chapterInfos = try await extractChaptersFromFile(url)
            print("   📖 Extracted \(chapterInfos.count) chapters")
            
            for chapterInfo in chapterInfos {
                let chapter = Chapter(
                    index: chapterInfo.index,
                    title: chapterInfo.title,
                    startTime: chapterInfo.startTime,
                    duration: chapterInfo.duration
                )
                audiobook.chapters?.append(chapter)
            }
        } catch {
            print("   ⚠️ Failed to extract chapters: \(error)")
        }
        
        // 6. Create initial playback session
        let session = PlaybackSession()
        audiobook.playbackSession = session
        print("   ⏯️ Playback session created")
        
        // 7. Cache locally on iPhone for immediate playback
        print("   💾 Caching locally for immediate playback...")
        _ = try cacheManager.cacheAudiobook(audiobook, from: url)
        print("   ✅ Cached locally at: \(audiobook.expectedCachePath)")
        
        // 8. Save to SwiftData (will sync via CloudKit to Watch)
        modelContext.insert(audiobook)
        try modelContext.save()
        print("   💾 Saved to database")
        
        // 9. Cleanup old caches if needed
        try await cacheManager.cleanupIfNeeded()
        
        print("   ✅ Import complete!")
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
        print("🔄 Starting library refresh from iCloud Drive...")
        isRefreshing = true
        lastError = nil
        
        defer {
            isRefreshing = false
        }
        
        do {
            // 1. Fetch all M4B files from iCloud Drive
            let metadataList = try await iCloudProvider.fetchLibrary()
            print("   📚 Found \(metadataList.count) M4B files in iCloud Drive")
            
            // 2. Get existing audiobooks from database
            let descriptor = FetchDescriptor<Audiobook>()
            let existingAudiobooks = try modelContext.fetch(descriptor)
            let existingPaths = Set(existingAudiobooks.compactMap { $0.iCloudRelativePath })
            
            // 3. Import new files that aren't already in the library
            var importedCount = 0
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
                    print("   ⏭️ Skipping \(metadata.title) (already in library)")
                    continue
                }
                
                // Import the new file
                do {
                    print("   📥 Importing: \(metadata.title)")
                    _ = try await importFile(from: url)
                    importedCount += 1
                } catch {
                    print("   ⚠️ Failed to import \(metadata.title): \(error)")
                }
            }
            
            print("✅ Library refresh complete: \(importedCount) new audiobooks imported")
            
        } catch {
            print("❌ Library refresh failed: \(error)")
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
        print("🗑️ [Delete] ===== STARTING DELETION =====")
        print("🗑️ [Delete] Title: \(audiobook.title)")
        print("🗑️ [Delete] ID: \(audiobook.id)")
        print("🗑️ [Delete] Filename: \(audiobook.filename ?? "nil")")
        print("🗑️ [Delete] Expected cache path: \(audiobook.expectedCachePath ?? "nil")")
        print("🗑️ [Delete] Is cached: \(audiobook.isFileCached)")
        print("🗑️ [Delete] Delete from iCloud: \(deleteFromiCloud)")
        
        // IMPORTANT: Force load external storage attributes before deletion
        // This resolves the fault so SwiftData can properly clean up external storage
        print("   🗑️ [Delete] Resolving external storage faults...")
        _ = audiobook.artworkData  // Force load the artwork data fault
        print("   ✅ [Delete] External storage faults resolved")
        
        var errors: [Error] = []
        
        // 1. Delete local cache
        do {
            try cacheManager.deleteCachedFile(for: audiobook)
            print("   ✅ [Delete] Deleted local cache")
        } catch {
            print("   ⚠️ [Delete] Failed to delete local cache: \(error)")
            errors.append(error)
            // Continue - not a fatal error
        }
        
        // 2. Delete from iCloud Drive if requested
        if deleteFromiCloud, let iCloudPath = audiobook.iCloudRelativePath {
            if let ubiquityURL = FileManager.default.url(
                forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
            ) {
                let iCloudFileURL = ubiquityURL.appendingPathComponent(iCloudPath)
                
                print("   🗑️ [Delete] Attempting to delete from iCloud Drive: \(iCloudFileURL.path)")
                
                // Use NSFileCoordinator for iCloud files
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var deleteError: Error?
                
                coordinator.coordinate(writingItemAt: iCloudFileURL, options: .forDeleting, error: &coordinationError) { url in
                    do {
                        // Check if file exists first
                        if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                            print("   ✅ [Delete] Deleted from iCloud Drive")
                        } else {
                            print("   ℹ️ [Delete] File doesn't exist in iCloud (already deleted or never uploaded)")
                        }
                    } catch {
                        print("   ⚠️ [Delete] Failed to delete from iCloud: \(error)")
                        deleteError = error
                    }
                }
                
                if let error = coordinationError {
                    print("   ⚠️ [Delete] Coordination error: \(error)")
                    errors.append(error)
                }
                if let error = deleteError {
                    errors.append(error)
                }
            } else {
                let error = AudiobookError.cloudKitUnavailable
                print("   ⚠️ [Delete] Cannot access iCloud container")
                errors.append(error)
            }
        }
        
        // 3. Delete relationships (chapters, playback session, cache entry)
        // SwiftData should handle this with cascade delete rules, but let's be explicit
        print("   🗑️ [Delete] Deleting relationships...")
        
        if let chapters = audiobook.chapters {
            print("   🗑️ [Delete] Found \(chapters.count) chapters to delete")
        }
        if let session = audiobook.playbackSession {
            print("   🗑️ [Delete] Found playback session to delete")
        }
        if let cache = audiobook.cacheEntry {
            print("   🗑️ [Delete] Found cache entry to delete")
        }
        
        // 4. Delete from SwiftData (will sync deletion via CloudKit to Watch)
        print("   🗑️ [Delete] Deleting from SwiftData/CloudKit...")
        print("   📡 [Delete] Model will sync to CloudKit container: iCloud.com.anarkisti.Listen-This")
        
        modelContext.delete(audiobook)
        
        do {
            try modelContext.save()
            print("   ✅ [Delete] Saved deletion to SwiftData")
            print("   📡 [Delete] CloudKit sync initiated (may take a moment)")
            print("   📡 [Delete] Watch and other devices will receive deletion via CloudKit sync")
        } catch {
            print("   ❌ [Delete] CRITICAL: Failed to save deletion: \(error)")
            print("   ❌ [Delete] Error type: \(type(of: error))")
            print("   ❌ [Delete] Error details: \(error.localizedDescription)")
            throw error  // This is a fatal error
        }
        
        // Report completion
        if errors.isEmpty {
            print("✅ [Delete] ===== DELETION COMPLETE =====")
            print("✅ [Delete] Audiobook '\(audiobook.title)' deleted successfully")
            print("📡 [Delete] CloudKit will sync deletion to other devices")
        } else {
            print("⚠️ [Delete] ===== DELETION COMPLETE WITH WARNINGS =====")
            print("⚠️ [Delete] Audiobook '\(audiobook.title)' deleted with \(errors.count) warning(s)")
            for (index, error) in errors.enumerated() {
                print("   Warning \(index + 1): \(error.localizedDescription)")
            }
            // Don't throw - deletion from database succeeded which is most important
        }
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

