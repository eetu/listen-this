//
//  AudiobookshelfProvider.swift
//  Listen This
//
//  Audiobookshelf server integration via REST API
//

import Foundation
import OSLog

// MARK: - API Response Models

struct AudiobookshelfLoginResponse: Codable {
    let user: AudiobookshelfUser
    let userDefaultLibraryId: String

    struct AudiobookshelfUser: Codable {
        let id: String
        let username: String
        let token: String
        let librariesAccessible: [String]
    }
}

struct AudiobookshelfLibraryItemsResponse: Codable {
    let results: [AudiobookshelfLibraryItem]
    let total: Int
}

struct AudiobookshelfLibraryItem: Codable {
    let id: String
    let libraryId: String
    let media: AudiobookshelfMedia
    let addedAt: Int64
    let updatedAt: Int64

    struct AudiobookshelfMedia: Codable {
        let metadata: AudiobookshelfMetadata
        let coverPath: String?
        let duration: Double?
        let size: Int64?
        let tracks: [AudiobookshelfTrack]?
        let chapters: [AudiobookshelfChapter]?

        struct AudiobookshelfMetadata: Codable {
            let title: String?
            let subtitle: String?
            let authorName: String?
            let narratorName: String?
            let description: String?
            let publishedYear: String?
            let publisher: String?
            let isbn: String?
            let asin: String?
            let language: String?
            let genres: [String]?
        }

        struct AudiobookshelfTrack: Codable {
            let index: Int
            let startOffset: Double
            let duration: Double
            let title: String?
            let contentUrl: String
            let mimeType: String
        }

        struct AudiobookshelfChapter: Codable {
            let id: Int
            let start: Double
            let end: Double
            let title: String
        }
    }
}

struct AudiobookshelfPlaybackSessionResponse: Codable {
    let id: String
    let userId: String
    let libraryId: String
    let libraryItemId: String
    let mediaType: String
    let displayTitle: String?
    let duration: Double
    let playMethod: Int
    let mediaPlayer: String
    let startTime: Double
}

// MARK: - Audiobookshelf Error

enum AudiobookshelfError: Error, LocalizedError {
    case invalidServerURL
    case authenticationFailed
    case networkError(Error)
    case invalidResponse
    case libraryNotFound
    case itemNotFound
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Invalid server URL"
        case .authenticationFailed:
            return "Authentication failed. Check your username and password."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .libraryNotFound:
            return "Library not found"
        case .itemNotFound:
            return "Item not found"
        case .noToken:
            return "No authentication token available"
        }
    }
}

// MARK: - Audiobookshelf Provider

@MainActor
final class AudiobookshelfProvider: ContentSource {

    private let logger = Logger(
        subsystem: "com.anarkisti.Listen-This", category: "AudiobookshelfProvider")

    // MARK: - State

    private var authToken: String?
    private var defaultLibraryId: String?
    private var serverURL: URL?

    // MARK: - Session

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: - Authentication

    /// Authenticate using API key (recommended)
    func authenticateWithAPIKey(serverURL: URL, apiKey: String) async throws {
        self.serverURL = serverURL
        self.authToken = apiKey

        // Validate the API key by fetching user info

        let meURL = serverURL.appendingPathComponent("api").appendingPathComponent("me")
        var request = URLRequest(url: meURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AudiobookshelfError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                logger.error(
                    "API key validation failed with status code: \(httpResponse.statusCode)")
                throw AudiobookshelfError.authenticationFailed
            }

            // Parse user info to get default library
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Check if user has access to all libraries
                if let permissions = json["permissions"] as? [String: Any],
                    let accessAllLibraries = permissions["accessAllLibraries"] as? Int,
                    accessAllLibraries == 1
                {
                    // User has access to all libraries - we'll fetch the first library when needed
                } else if let librariesAccessible = json["librariesAccessible"] as? [String],
                    let firstLibrary = librariesAccessible.first
                {
                    // User has specific libraries accessible
                    defaultLibraryId = firstLibrary
                }
            } else {
                logger.error("Failed to parse /me response as JSON")
                throw AudiobookshelfError.invalidResponse
            }

        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            logger.error(
                "Network error during API key authentication: \(error.localizedDescription)")
            throw AudiobookshelfError.networkError(error)
        }
    }

    /// Authenticate using username/password (legacy, less secure)
    func authenticate(credentials: Credentials) async throws {
        guard let serverURL = credentials.serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let username = credentials.username,
            let password = credentials.password
        else {
            throw AudiobookshelfError.authenticationFailed
        }

        self.serverURL = serverURL

        // Login endpoint: POST /login
        let loginURL = serverURL.appendingPathComponent("login")
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let loginData = [
            "username": username,
            "password": password,
        ]

        request.httpBody = try JSONEncoder().encode(loginData)

        logger.info("Authenticating with Audiobookshelf at \(loginURL.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AudiobookshelfError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                logger.error("Authentication failed with status code: \(httpResponse.statusCode)")
                throw AudiobookshelfError.authenticationFailed
            }

            let loginResponse = try JSONDecoder().decode(
                AudiobookshelfLoginResponse.self, from: data)

            authToken = loginResponse.user.token
            defaultLibraryId = loginResponse.userDefaultLibraryId

            logger.info(
                "Authentication successful. Default library: \(self.defaultLibraryId ?? "none")")

        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            logger.error("Network error during authentication: \(error.localizedDescription)")
            throw AudiobookshelfError.networkError(error)
        }
    }

    func validateAccess() async throws -> Bool {
        guard authToken != nil else {
            return false
        }

        // Try to fetch libraries to validate token
        do {
            _ = try await fetchLibrary()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Library Management

    func fetchLibrary() async throws -> [AudiobookMetadata] {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // If we don't have a default library ID, fetch the list of libraries first
        var libraryId = defaultLibraryId
        if libraryId == nil {
            libraryId = try await fetchFirstLibraryId()
        }

        guard let libraryId = libraryId else {
            throw AudiobookshelfError.libraryNotFound
        }

        // GET /api/libraries/{id}/items
        let libraryURL =
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("libraries")
            .appendingPathComponent(libraryId)
            .appendingPathComponent("items")

        var request = URLRequest(url: libraryURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AudiobookshelfError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                logger.error("Library fetch failed with status code: \(httpResponse.statusCode)")
                throw AudiobookshelfError.libraryNotFound
            }

            let itemsResponse = try JSONDecoder().decode(
                AudiobookshelfLibraryItemsResponse.self, from: data)

            // Convert to AudiobookMetadata
            return itemsResponse.results.compactMap { item in
                convertToMetadata(item: item, serverURL: serverURL)
            }

        } catch let error as AudiobookshelfError {
            throw error
        } catch {
            logger.error("Network error fetching library: \(error.localizedDescription)")
            throw AudiobookshelfError.networkError(error)
        }
    }

    private func fetchFirstLibraryId() async throws -> String {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // GET /api/libraries to get list of all libraries
        let librariesURL =
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("libraries")

        var request = URLRequest(url: librariesURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AudiobookshelfError.libraryNotFound
        }

        // Parse the libraries array
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let libraries = json["libraries"] as? [[String: Any]],
            let firstLibrary = libraries.first,
            let libraryId = firstLibrary["id"] as? String
        {
            defaultLibraryId = libraryId
            return libraryId
        }

        throw AudiobookshelfError.libraryNotFound
    }

    func getAudiobookMetadata(identifier: String) async throws -> AudiobookMetadata {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // GET /api/items/{id}
        let itemURL =
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("items")
            .appendingPathComponent(identifier)

        var request = URLRequest(url: itemURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AudiobookshelfError.itemNotFound
        }

        let item = try JSONDecoder().decode(AudiobookshelfLibraryItem.self, from: data)

        guard let metadata = convertToMetadata(item: item, serverURL: serverURL) else {
            throw AudiobookshelfError.invalidResponse
        }

        return metadata
    }

    func searchLibrary(query: String) async throws -> [AudiobookMetadata] {
        // Simple client-side filtering for now
        let allItems = try await fetchLibrary()
        let lowercaseQuery = query.lowercased()

        return allItems.filter {
            $0.title.lowercased().contains(lowercaseQuery)
                || $0.author.lowercased().contains(lowercaseQuery)
                || ($0.narrator?.lowercased().contains(lowercaseQuery) ?? false)
        }
    }

    // MARK: - Content Access

    func getStreamURL(identifier: String) async throws -> URL {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // First, fetch item details with expanded=1 to get the track's contentUrl (which includes the file ino)
        // This is needed because /api/items/{id}/file/{ino} is the proper streaming endpoint
        var itemComponents = URLComponents(
            url: serverURL
                .appendingPathComponent("api")
                .appendingPathComponent("items")
                .appendingPathComponent(identifier),
            resolvingAgainstBaseURL: false
        )
        // expanded=1 is required to get track information including contentUrl
        itemComponents?.queryItems = [URLQueryItem(name: "expanded", value: "1")]
        
        guard let itemURL = itemComponents?.url else {
            throw AudiobookshelfError.invalidServerURL
        }

        var itemRequest = URLRequest(url: itemURL)
        itemRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (itemData, itemResponse) = try await session.data(for: itemRequest)

        guard let itemHttpResponse = itemResponse as? HTTPURLResponse,
              itemHttpResponse.statusCode == 200 else {
            throw AudiobookshelfError.itemNotFound
        }

        let item = try JSONDecoder().decode(AudiobookshelfLibraryItem.self, from: itemData)

        // Get the first track's contentUrl (format: /api/items/{id}/file/{ino})
        // For single-file M4B audiobooks, there's typically one track
        if let firstTrack = item.media.tracks?.first {
            // contentUrl is a relative path like "/api/items/{id}/file/{ino}"
            // We need to construct the full URL with the server base and auth token
            var streamComponents = URLComponents(
                url: serverURL.appendingPathComponent(firstTrack.contentUrl),
                resolvingAgainstBaseURL: false
            )
            streamComponents?.queryItems = [URLQueryItem(name: "token", value: token)]

            if let streamURL = streamComponents?.url {
                logger.info("Generated stream URL from track contentUrl: \(streamURL.absoluteString)")
                return streamURL
            }
        }

        // Fallback to /download endpoint if no tracks found (for backwards compatibility)
        logger.warning("No tracks found, falling back to /download endpoint")
        var fallbackComponents = URLComponents(
            url:
                serverURL
                .appendingPathComponent("api")
                .appendingPathComponent("items")
                .appendingPathComponent(identifier)
                .appendingPathComponent("download"), resolvingAgainstBaseURL: false)

        fallbackComponents?.queryItems = [URLQueryItem(name: "token", value: token)]

        guard let streamURL = fallbackComponents?.url else {
            throw AudiobookshelfError.invalidServerURL
        }

        logger.info("Generated stream URL (fallback): \(streamURL.absoluteString)")
        return streamURL
    }

    func getDownloadURL(identifier: String) async throws -> URL {
        // Same as stream URL for Audiobookshelf
        return try await getStreamURL(identifier: identifier)
    }

    func getArtwork(identifier: String) async throws -> Data {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // GET /api/items/{id}/cover with high resolution
        // Audiobookshelf supports width/height parameters for cover resizing
        // Request 800x800 for good quality on all devices (iPhone, iPad)
        var components = URLComponents(
            url:
                serverURL
                .appendingPathComponent("api")
                .appendingPathComponent("items")
                .appendingPathComponent(identifier)
                .appendingPathComponent("cover"), resolvingAgainstBaseURL: false)

        components?.queryItems = [
            URLQueryItem(name: "width", value: "1024"),
            URLQueryItem(name: "height", value: "1024"),
            URLQueryItem(name: "format", value: "jpeg"),
        ]

        guard let coverURL = components?.url else {
            throw AudiobookshelfError.invalidServerURL
        }

        var request = URLRequest(url: coverURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AudiobookshelfError.itemNotFound
        }

        return data
    }

    // MARK: - Chapter Information

    /// Get chapter/track information for an audiobook
    func getChapters(identifier: String) async throws -> [ChapterInfo] {
        guard let serverURL = serverURL else {
            throw AudiobookshelfError.invalidServerURL
        }

        guard let token = authToken else {
            throw AudiobookshelfError.noToken
        }

        // GET /api/items/{id}?expanded=1 to get full item with tracks
        // The expanded parameter is needed to get track/chapter information
        var components = URLComponents(
            url:
                serverURL
                .appendingPathComponent("api")
                .appendingPathComponent("items")
                .appendingPathComponent(identifier),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "expanded", value: "1")]

        guard let itemURL = components?.url else {
            throw AudiobookshelfError.invalidServerURL
        }

        var request = URLRequest(url: itemURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        logger.info("Fetching chapters from: \(itemURL.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logger.error(
                "Failed to fetch item for chapters. Status: \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
            throw AudiobookshelfError.itemNotFound
        }

        // Debug: log a preview of the response
        if let jsonString = String(data: data, encoding: .utf8) {
            logger.debug(
                "API Response preview (first 1000 chars): \(String(jsonString.prefix(1000)))")
        }

        let item = try JSONDecoder().decode(AudiobookshelfLibraryItem.self, from: data)

        // Prefer embedded chapters (for M4B files) over tracks
        if let absChapters = item.media.chapters, !absChapters.isEmpty {
            logger.info("Found \(absChapters.count) embedded chapters for item \(identifier)")

            var chapters: [ChapterInfo] = []

            for (index, chapter) in absChapters.enumerated() {
                let duration = chapter.end - chapter.start
                let chapterInfo = ChapterInfo(
                    index: index,
                    title: chapter.title,
                    startTime: chapter.start,
                    duration: duration
                )
                chapters.append(chapterInfo)
            }

            logger.info("Converted \(chapters.count) embedded chapters to chapter info")
            return chapters
        }

        // Fall back to tracks (for multi-file audiobooks)
        guard let tracks = item.media.tracks, !tracks.isEmpty else {
            logger.warning("No chapters or tracks found in media for item \(identifier)")
            return []
        }

        logger.info("Found \(tracks.count) tracks for item \(identifier), using as chapters")

        var chapters: [ChapterInfo] = []
        var cumulativeTime: Double = 0

        for track in tracks.sorted(by: { $0.index < $1.index }) {
            let chapterInfo = ChapterInfo(
                index: track.index,
                title: track.title ?? "Chapter \(track.index + 1)",
                startTime: cumulativeTime,
                duration: track.duration
            )
            chapters.append(chapterInfo)
            cumulativeTime += track.duration
        }

        logger.info("Converted \(chapters.count) tracks to chapter info")

        return chapters
    }

    // MARK: - Progress Sync (Optional)

    func syncProgress(identifier: String, position: Double) async throws {
        // Progress sync to Audiobookshelf server is a future enhancement
        // Would use POST /api/session/{sessionId}/sync
    }

    func getProgress(identifier: String) async throws -> Double? {
        // Progress fetch from Audiobookshelf server is a future enhancement
        return nil
    }

    // MARK: - Helper Methods

    private func convertToMetadata(item: AudiobookshelfLibraryItem, serverURL: URL)
        -> AudiobookMetadata?
    {
        let metadata = item.media.metadata

        guard let title = metadata.title else {
            return nil
        }

        let author = metadata.authorName ?? "Unknown Author"
        let duration = item.media.duration ?? 0
        let fileSize = item.media.size ?? 0
        let chapterCount = item.media.tracks?.count ?? 0

        let addedDate = Date(timeIntervalSince1970: TimeInterval(item.addedAt) / 1000.0)

        // Build artwork URL with higher resolution for better quality
        var artworkURL: URL? = nil
        if item.media.coverPath != nil {
            var components = URLComponents(
                url:
                    serverURL
                    .appendingPathComponent("api")
                    .appendingPathComponent("items")
                    .appendingPathComponent(item.id)
                    .appendingPathComponent("cover"), resolvingAgainstBaseURL: false)

            // Request 400x400 for browser thumbnails (smaller than full artwork)
            components?.queryItems = [
                URLQueryItem(name: "width", value: "400"),
                URLQueryItem(name: "height", value: "400"),
                URLQueryItem(name: "format", value: "jpeg"),
            ]

            artworkURL = components?.url
        }

        return AudiobookMetadata(
            identifier: item.id,
            title: title,
            author: author,
            narrator: metadata.narratorName,
            duration: duration,
            fileSize: fileSize,
            sourceType: "audiobookshelf",
            sourceURL: serverURL.absoluteString,
            chapterCount: chapterCount,
            addedDate: addedDate,
            artworkURL: artworkURL
        )
    }
}
