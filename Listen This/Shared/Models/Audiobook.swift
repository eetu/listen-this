//
//  Audiobook.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation
import SwiftData

@Model
final class Audiobook {
    var id: UUID = UUID.init()
    var title: String = ""
    var author: String = ""
    var narrator: String?
    
    // IMPORTANT: External storage attributes must be accessed (fault resolved) before deletion
    // Otherwise SwiftData will crash with "This backing data was detached from a context without resolving attribute faults"
    // See AudiobookLibraryService.deleteAudiobook() for the fault resolution pattern
    @Attribute(.externalStorage) var artworkData: Data?
    
    var duration: Double = 0  // Total duration in seconds
    var fileSize: Int64 = 0   // File size in bytes
    
    // Storage - Simple iCloud Drive path reference (syncs via CloudKit)
    var iCloudRelativePath: String?  // e.g. "Documents/Audiobooks/book.m4b"
    var localFilename: String?  // The actual filename (e.g. "The Hobbit.m4b")
    
    // Metadata
    var downloadDate: Date?
    var lastAccessedDate: Date = Date()
    var lastSyncedDate: Date = Date()
    var chapterCount: Int = 0
    var isArchived: Bool = false
    
    @Relationship(deleteRule: .cascade) var chapters: [Chapter]?
    @Relationship(deleteRule: .cascade) var playbackSession: PlaybackSession?
    @Relationship(deleteRule: .cascade) var cacheEntry: CacheEntry?
    
    init(
        id: UUID = UUID(),
        title: String = "",
        author: String = "",
        narrator: String? = nil,
        artworkData: Data? = nil,
        duration: Double = 0,
        fileSize: Int64 = 0,
        iCloudRelativePath: String? = nil,
        localFilename: String? = nil,
        downloadDate: Date? = nil,
        lastAccessedDate: Date = Date(),
        lastSyncedDate: Date = Date(),
        chapterCount: Int = 0,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.narrator = narrator
        self.artworkData = artworkData
        self.duration = duration
        self.fileSize = fileSize
        self.iCloudRelativePath = iCloudRelativePath
        self.localFilename = localFilename
        self.downloadDate = downloadDate
        self.lastAccessedDate = lastAccessedDate
        self.lastSyncedDate = lastSyncedDate
        self.chapterCount = chapterCount
        self.isArchived = isArchived
        self.chapters = []  // Initialize empty chapters array
    }
    
    // MARK: - Computed Properties (Not Stored, Not Synced)
    
    /// Get the filename for this audiobook
    var filename: String? {
        // Use stored localFilename if available
        return localFilename
    }
    
    /// Get the expected local cache path for this device
    var expectedCachePath: String? {
        // On iOS/macOS, use Caches directory as it's more appropriate
        // for downloaded content that can be re-downloaded
        guard let filename = filename else { return nil }
        
        let storageDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")
        
        return storageDir.appendingPathComponent(filename).path
    }
    
    /// Check if file is cached locally (computed on-demand)
    var isFileCached: Bool {
        guard let cachePath = expectedCachePath else { return false }
        return FileManager.default.fileExists(atPath: cachePath)
    }
    
    /// Get the cache file URL if it exists
    var cacheFileURL: URL? {
        guard let cachePath = expectedCachePath else { return nil }
        let url = URL(fileURLWithPath: cachePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    
    /// Get valid cache file URL for transfers (returns URL even if file doesn't exist yet)
    /// This is useful for checking if we have the path available, then verifying existence separately
    var validCacheFileURL: URL? {
        guard let cachePath = expectedCachePath else { return nil }
        return URL(fileURLWithPath: cachePath)
    }
    
    /// Get the iCloud file URL (full path)
    var iCloudFileURL: URL? {
        guard let relativePath = iCloudRelativePath else { return nil }
        guard let ubiquityURL = FileManager.default.url(
            forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
        ) else { return nil }
        
        return ubiquityURL.appendingPathComponent(relativePath)
    }
}
