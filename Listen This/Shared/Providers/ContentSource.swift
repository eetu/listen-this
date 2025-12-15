//
//  ContentSource.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation

/// Protocol defining how to access audiobook content from various sources
protocol ContentSource {
    // MARK: - Authentication
    
    /// Authenticate with the content source using provided credentials
    func authenticate(credentials: Credentials) async throws
    
    /// Validate current access to the content source
    func validateAccess() async throws -> Bool
    
    // MARK: - Library Management
    
    /// Fetch the complete library of audiobooks from this source
    func fetchLibrary() async throws -> [AudiobookMetadata]
    
    /// Get detailed metadata for a specific audiobook
    func getAudiobookMetadata(identifier: String) async throws -> AudiobookMetadata
    
    /// Search the library with a query string
    func searchLibrary(query: String) async throws -> [AudiobookMetadata]
    
    // MARK: - Content Access
    
    /// Get a streaming URL for the audiobook
    func getStreamURL(identifier: String) async throws -> URL
    
    /// Get a download URL for the audiobook
    func getDownloadURL(identifier: String) async throws -> URL
    
    /// Get artwork data for the audiobook
    func getArtwork(identifier: String) async throws -> Data
    
    // MARK: - Optional: Server-side Progress Sync
    
    /// Sync playback progress to the server (optional)
    func syncProgress(identifier: String, position: Double) async throws
    
    /// Get playback progress from the server (optional)
    func getProgress(identifier: String) async throws -> Double?
}

// MARK: - Supporting Types

/// Credentials for authenticating with a content source
struct Credentials {
    let username: String?
    let password: String?
    let apiKey: String?
    let serverURL: URL?
    
    init(username: String? = nil, password: String? = nil, apiKey: String? = nil, serverURL: URL? = nil) {
        self.username = username
        self.password = password
        self.apiKey = apiKey
        self.serverURL = serverURL
    }
}

/// Metadata about an audiobook from a content source
struct AudiobookMetadata {
    let identifier: String
    let title: String
    let author: String
    let narrator: String?
    let duration: Double
    let fileSize: Int64
    let sourceType: String
    let sourceURL: String
    let chapterCount: Int
    let addedDate: Date
    var artworkURL: URL?
    
    init(
        identifier: String,
        title: String,
        author: String,
        narrator: String? = nil,
        duration: Double,
        fileSize: Int64,
        sourceType: String,
        sourceURL: String,
        chapterCount: Int,
        addedDate: Date = Date(),
        artworkURL: URL? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.author = author
        self.narrator = narrator
        self.duration = duration
        self.fileSize = fileSize
        self.sourceType = sourceType
        self.sourceURL = sourceURL
        self.chapterCount = chapterCount
        self.addedDate = addedDate
        self.artworkURL = artworkURL
    }
}
