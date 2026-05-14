//
//  ContentSource.swift
//  listen this
//

import Foundation

/// Protocol defining how to access audiobook content from various sources
@MainActor
protocol ContentSource: AnyObject {
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

    init(
        username: String? = nil, password: String? = nil, apiKey: String? = nil,
        serverURL: URL? = nil
    ) {
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
// MARK: - Mock Implementation (Previews & Testing)

#if DEBUG

@MainActor
final class MockContentSource: ContentSource {
    var isAuthenticated = false
    var mockLibrary: [AudiobookMetadata] = []

    init() {
        // Create some mock audiobooks
        mockLibrary = [
            AudiobookMetadata(
                identifier: "mock-1",
                title: "The Great Gatsby",
                author: "F. Scott Fitzgerald",
                narrator: "Jake Gyllenhaal",
                duration: 14400,
                fileSize: 150_000_000,
                sourceType: "icloud",
                sourceURL: "mock://book1.m4b",
                chapterCount: 9,
                addedDate: Date()
            ),
            AudiobookMetadata(
                identifier: "mock-2",
                title: "1984",
                author: "George Orwell",
                narrator: "Simon Prebble",
                duration: 36000,
                fileSize: 350_000_000,
                sourceType: "icloud",
                sourceURL: "mock://book2.m4b",
                chapterCount: 23,
                addedDate: Date().addingTimeInterval(-86400)
            ),
            AudiobookMetadata(
                identifier: "mock-3",
                title: "To Kill a Mockingbird",
                author: "Harper Lee",
                narrator: "Sissy Spacek",
                duration: 43200,
                fileSize: 420_000_000,
                sourceType: "icloud",
                sourceURL: "mock://book3.m4b",
                chapterCount: 31,
                addedDate: Date().addingTimeInterval(-172800)
            ),
        ]
    }

    func authenticate(credentials: Credentials) async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
        isAuthenticated = true
    }

    func validateAccess() async throws -> Bool {
        return isAuthenticated
    }

    func fetchLibrary() async throws -> [AudiobookMetadata] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return mockLibrary
    }

    func getAudiobookMetadata(identifier: String) async throws -> AudiobookMetadata {
        guard let metadata = mockLibrary.first(where: { $0.identifier == identifier }) else {
            throw AudiobookError.fileNotFound
        }
        return metadata
    }

    func searchLibrary(query: String) async throws -> [AudiobookMetadata] {
        let lowercaseQuery = query.lowercased()
        return mockLibrary.filter {
            $0.title.lowercased().contains(lowercaseQuery)
                || $0.author.lowercased().contains(lowercaseQuery)
                || ($0.narrator?.lowercased().contains(lowercaseQuery) ?? false)
        }
    }

    func getStreamURL(identifier: String) async throws -> URL {
        return URL(fileURLWithPath: "/mock/\(identifier).m4b")
    }

    func getDownloadURL(identifier: String) async throws -> URL {
        return URL(fileURLWithPath: "/mock/\(identifier).m4b")
    }

    func getArtwork(identifier: String) async throws -> Data {
        // Return empty data for mock
        return Data()
    }

    func syncProgress(identifier: String, position: Double) async throws {
        // Mock: Progress synced
    }

    func getProgress(identifier: String) async throws -> Double? {
        return nil
    }
}

#endif
