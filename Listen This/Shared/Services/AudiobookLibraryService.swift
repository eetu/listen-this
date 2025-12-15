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
    
    var isRefreshing = false
    var lastError: AudiobookError?
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Library Operations
    
    /// Refresh library from iCloud Drive
    func refreshLibrary() async {
        guard !isRefreshing else { return }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        do {
            // Validate iCloud Drive access
            guard try await iCloudProvider.validateAccess() else {
                lastError = .cloudKitUnavailable
                return
            }
            
            // Fetch metadata from iCloud Drive
            let metadataList = try await iCloudProvider.fetchLibrary()
            
            // Import into SwiftData
            for metadata in metadataList {
                try await importAudiobook(from: metadata)
            }
            
            lastError = nil
        } catch let error as AudiobookError {
            lastError = error
        } catch {
            lastError = .unknown(error)
        }
    }
    
    /// Import a single audiobook from metadata
    private func importAudiobook(from metadata: AudiobookMetadata) async throws {
        print("📥 Importing audiobook: \(metadata.title)")
        
        // Check if audiobook already exists
        let sourceURL = metadata.sourceURL
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.sourcePath == sourceURL }
        )
        
        let existing = try modelContext.fetch(descriptor)
        
        if !existing.isEmpty {
            // Update existing audiobook
            if let audiobook = existing.first {
                print("   ℹ️ Audiobook already exists, updating...")
                updateAudiobook(audiobook, with: metadata)
            }
        } else {
            // Create new audiobook
            print("   ✨ Creating new audiobook...")
            try await createAudiobook(from: metadata)
        }
        
        try modelContext.save()
        print("   ✅ Saved to SwiftData")
    }
    
    /// Create a new audiobook from metadata
    private func createAudiobook(from metadata: AudiobookMetadata) async throws {
        print("      📚 Creating audiobook model...")
        
        // Extract artwork
        var artworkData: Data?
        do {
            artworkData = try await iCloudProvider.getArtwork(identifier: metadata.identifier)
            print("      🖼️ Artwork extracted")
        } catch {
            print("      ⚠️ No artwork available")
        }
        
        // Create audiobook model
        let audiobook = Audiobook(
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            artworkData: artworkData,
            duration: metadata.duration,
            fileSize: metadata.fileSize,
            sourceType: metadata.sourceType,
            sourcePath: metadata.sourceURL,
            localFilePath: metadata.sourceURL, // For iCloud Drive, this is the local path
            isCached: true, // iCloud Drive files are considered cached
            downloadDate: metadata.addedDate,
            chapterCount: metadata.chapterCount
        )
        
        print("      🎯 Audiobook object created")
        print("         ID: \(audiobook.id)")
        print("         Title: \(audiobook.title)")
        print("         Source: \(audiobook.sourcePath)")
        
        // Extract and create chapters
        if let url = URL(string: metadata.identifier) {
            do {
                let chapterInfos = try await iCloudProvider.extractChapters(from: url)
                print("      📖 Extracted \(chapterInfos.count) chapters")
                
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
                print("      ⚠️ Failed to extract chapters: \(error)")
            }
        }
        
        // Create initial playback session
        let session = PlaybackSession()
        audiobook.playbackSession = session
        print("      ⏯️ Playback session created")
        
        // Insert into context
        modelContext.insert(audiobook)
        print("      ✅ Inserted into model context")
    }
    
    /// Update an existing audiobook with new metadata
    private func updateAudiobook(_ audiobook: Audiobook, with metadata: AudiobookMetadata) {
        audiobook.title = metadata.title
        audiobook.author = metadata.author
        audiobook.narrator = metadata.narrator
        audiobook.duration = metadata.duration
        audiobook.fileSize = metadata.fileSize
        audiobook.chapterCount = metadata.chapterCount
        audiobook.lastSyncedDate = Date()
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
        
        // Copy file to iCloud Drive
        print("   📋 Copying to iCloud Drive...")
        let destinationURL = try await iCloudProvider.importFile(from: url)
        print("   ✅ Copied to: \(destinationURL.lastPathComponent)")
        
        // Extract metadata
        print("   🔍 Extracting metadata...")
        let metadata = try await iCloudProvider.getAudiobookMetadata(identifier: destinationURL.absoluteString)
        print("   ✅ Metadata extracted: \(metadata.title)")
        
        // Create audiobook
        try await createAudiobook(from: metadata)
        
        // Save immediately to ensure data is persisted
        try modelContext.save()
        print("   💾 Saved to database")
        
        // Fetch and return the created audiobook
        let sourceURL = metadata.sourceURL
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.sourcePath == sourceURL }
        )
        
        let audiobooks = try modelContext.fetch(descriptor)
        print("   🔎 Fetched \(audiobooks.count) matching audiobook(s)")
        
        guard let audiobook = audiobooks.first else {
            print("   ❌ ERROR: Audiobook not found after creation!")
            throw AudiobookError.unknown(NSError(domain: "AudiobookLibraryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audiobook was created but could not be retrieved"]))
        }
        
        print("   ✅ Import complete!")
        return audiobook
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
    
    /// Delete an audiobook and its associated files
    func deleteAudiobook(_ audiobook: Audiobook) throws {
        // Delete local file if it exists
        if let localPath = audiobook.localFilePath,
           let url = URL(string: localPath) {
            try? FileManager.default.removeItem(at: url)
        }
        
        // Delete from context (cascade will handle relationships)
        modelContext.delete(audiobook)
        try modelContext.save()
    }
}
