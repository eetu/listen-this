//
//  Audiobook.swift
//  listen this
//

import Foundation
import SwiftData
import SwiftUI

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
    var fileSize: Int64 = 0  // File size in bytes

    // Storage - Simple iCloud Drive path reference (syncs via CloudKit)
    var iCloudRelativePath: String?  // e.g. "Documents/Audiobooks/book.m4b"

    // MARK: - Content Source

    /// Source type: "icloud", "audiobookshelf", "jellyfin"
    var sourceType: String = "icloud"

    /// Source-specific identifier (e.g., Audiobookshelf library item ID)
    var sourceIdentifier: String?

    /// Source URL for streaming/downloading (e.g., Audiobookshelf server + path)
    var sourceURL: String?

    // Metadata
    var lastAccessedDate: Date = Date()
    var chapterCount: Int = 0
    var isArchived: Bool = false

    @Relationship(deleteRule: .cascade) var chapters: [Chapter]?
    @Relationship(deleteRule: .cascade) var playbackSession: PlaybackSession?
    // CacheEntry is device-specific and should not sync via CloudKit
    // Each device maintains its own cache state independently
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
        lastAccessedDate: Date = Date(),
        chapterCount: Int = 0,
        isArchived: Bool = false,
        chapters: [Chapter] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.narrator = narrator
        self.artworkData = artworkData
        self.duration = duration
        self.fileSize = fileSize
        self.iCloudRelativePath = iCloudRelativePath
        self.lastAccessedDate = lastAccessedDate
        self.chapterCount = chapterCount
        self.isArchived = isArchived
        self.chapters = chapters
    }

    // MARK: - Computed Properties (Not Stored, Not Synced)

    /// Get the filename for this audiobook (provider-agnostic)
    /// - iCloud books: Use the filename from iCloudRelativePath
    /// - Remote sources: Use sourceIdentifier for stable caching across re-adds
    var filename: String? {
        // For iCloud books, use the original filename
        if let iCloudPath = iCloudRelativePath {
            return URL(fileURLWithPath: iCloudPath).lastPathComponent
        }

        // For remote sources, use sourceIdentifier to maintain cache across re-adds
        // This prevents re-downloading if user removes and re-adds the same book
        if let sourceId = sourceIdentifier {
            // Sanitize the identifier to make it filesystem-safe
            let sanitized = sourceId.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            return "\(sanitized).m4b"
        }

        // Fallback to UUID if no source identifier
        return "\(id).m4b"
    }

    /// Get the expected local cache path for this device
    var expectedCachePath: String? {
        guard let filename = filename else { return nil }

        let storageDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")

        return storageDir.appendingPathComponent(filename).path
    }

    /// Directory for bytes from an interrupted transfer.
    ///
    /// Deliberately *outside* the Audiobooks cache directory: anything sitting
    /// at `expectedCachePath` is treated as a complete, playable download, so a
    /// partial parked there would show as "Downloaded" and play silence past
    /// the point the bytes stop. Keeping partials separate makes that
    /// impossible. The orphan sweep also only scans the cache directory, so a
    /// resumable partial isn't deleted out from under a retry.
    static var partialsDirectoryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudiobookPartials")
    }

    /// Where an interrupted transfer parks its bytes for a later retry.
    var partialFileURL: URL? {
        guard let filename else { return nil }
        return Self.partialsDirectoryURL.appendingPathComponent("\(filename).partial")
    }

    /// Size of a resumable partial download, if one exists.
    var partialDownloadSize: Int64? {
        guard let url = partialFileURL,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            size > 0
        else { return nil }
        return size
    }

    /// Whether a previous transfer left bytes a retry could continue from.
    var hasPartialDownload: Bool {
        partialDownloadSize != nil
    }

    /// Check if file is cached locally (computed on-demand)
    var isFileCached: Bool {
        guard let cachePath = expectedCachePath else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath)
        guard let fileSize = attributes?[.size] as? Int64 else { return false }
        return fileSize > 0
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
        guard
            let ubiquityURL = FileManager.default.url(
                forUbiquityContainerIdentifier: "iCloud.com.anarkisti.Listen-This"
            )
        else { return nil }

        return ubiquityURL.appendingPathComponent(relativePath)
    }

    // MARK: - Availability States

    /// Check if this is an iCloud Drive audiobook
    var isICloudBook: Bool {
        sourceType == "icloud"
    }

    /// Check if this is an Audiobookshelf audiobook
    var isAudiobookshelfBook: Bool {
        sourceType == "audiobookshelf"
    }

    /// Check if this is a Jellyfin audiobook
    var isJellyfinBook: Bool {
        sourceType == "jellyfin"
    }

    /// Check if this book requires network streaming (not cached and from remote source)
    var requiresStreaming: Bool {
        !isFileCached && !isICloudBook
    }

    /// Check if this book can be played offline
    var canPlayOffline: Bool {
        isFileCached || (isICloudBook && iCloudFileURL != nil)
    }

    // MARK: - Playability State

    /// The current playability state of this audiobook
    var playabilityState: AudiobookPlayabilityState {
        // Cached locally - always playable offline
        if isFileCached {
            return .cached
        }

        // iCloud Drive books - need to be downloaded first
        if isICloudBook {
            return .requiresDownload
        }

        // Audiobookshelf/Jellyfin - can stream
        if isAudiobookshelfBook || isJellyfinBook {
            return .streamable
        }

        // Unknown source - requires download
        return .requiresDownload
    }
}

// MARK: - Playability State Enum

/// Represents the playability state of an audiobook
enum AudiobookPlayabilityState {
    /// File is cached locally and ready to play offline
    case cached

    /// Can be streamed over network (Audiobookshelf, Jellyfin)
    case streamable

    /// Requires download before playback (iCloud Drive, not yet cached)
    case requiresDownload

    /// Whether the audiobook can be played (either cached or streamable)
    var isPlayable: Bool {
        switch self {
        case .cached, .streamable:
            return true
        case .requiresDownload:
            return false
        }
    }

    /// Icon name for UI display
    var iconName: String {
        switch self {
        case .cached:
            return "checkmark.circle.fill"
        case .streamable:
            return "wifi"
        case .requiresDownload:
            return "icloud.slash"
        }
    }

    /// Status text for UI display
    var statusText: String {
        switch self {
        case .cached:
            return "Downloaded"
        case .streamable:
            return "Stream"
        case .requiresDownload:
            return "Not Downloaded"
        }
    }

    /// SwiftUI Color for UI display
    var color: Color {
        switch self {
        case .cached:
            return .green
        case .streamable:
            return .orange
        case .requiresDownload:
            return .orange
        }
    }
}
