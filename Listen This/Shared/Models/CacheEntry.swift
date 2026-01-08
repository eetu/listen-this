//
//  CacheEntry.swift
//  listen this
//

import Foundation
import SwiftData

@Model
final class CacheEntry {
    var id: UUID = UUID.init()
    var filePath: String = ""  // Local file path
    var fileSize: Int64 = 0  // Size in bytes
    var downloadedDate: Date = Date()  // When downloaded
    var lastAccessedDate: Date = Date()  // Last access for LRU
    var expirationDate: Date?  // Optional expiration

    @Relationship var audiobook: Audiobook?

    init(
        id: UUID = UUID(),
        filePath: String = "",
        fileSize: Int64 = 0,
        downloadedDate: Date = Date(),
        lastAccessedDate: Date = Date(),
        expirationDate: Date? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.fileSize = fileSize
        self.downloadedDate = downloadedDate
        self.lastAccessedDate = lastAccessedDate
        self.expirationDate = expirationDate
    }
}
