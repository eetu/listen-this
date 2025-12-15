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
    @Attribute(.externalStorage) var artworkData: Data?
    var duration: Double = 0  // Total duration in seconds
    var fileSize: Int64 = 0   // File size in bytes
    var sourceType: String = ""  // "icloud", "jellyfin", "audiobookshelf"
    var sourcePath: String = ""  // Original path/URL
    var localFilePath: String?  // Cached file path if downloaded
    var isCached: Bool = false
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
        sourceType: String = "",
        sourcePath: String = "",
        localFilePath: String? = nil,
        isCached: Bool = false,
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
        self.sourceType = sourceType
        self.sourcePath = sourcePath
        self.localFilePath = localFilePath
        self.isCached = isCached
        self.downloadDate = downloadDate
        self.lastAccessedDate = lastAccessedDate
        self.lastSyncedDate = lastSyncedDate
        self.chapterCount = chapterCount
        self.isArchived = isArchived
        self.chapters = []  // Initialize empty chapters array
    }
}
