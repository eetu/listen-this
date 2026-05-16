//
//  AudiobookshelfSettings.swift
//  Listen This
//
//  Model for storing Audiobookshelf server configuration
//

import Foundation
import OSLog
import SwiftData

// MARK: - Playback Mode

/// How to handle Audiobookshelf audiobook playback
enum AudiobookshelfPlaybackMode: String, Codable {
    /// Always stream, never cache locally
    case streamAlways

    /// Download manually when user chooses (default)
    case manualDownload

    /// Automatically download on WiFi for offline playback
    case autoDownload
}

// MARK: - Settings Model

@Model
final class AudiobookshelfSettings {
    // Use a fixed ID so there's only one Audiobookshelf settings record per user
    var id: String = "audiobookshelf_settings"

    // MARK: - Server Configuration

    /// Server URL (e.g., "http://192.168.1.123:13378")
    var serverURL: String = ""

    /// API key for authentication (synced via CloudKit)
    var apiKey: String = ""

    /// Whether Audiobookshelf integration is enabled
    var isEnabled: Bool = false

    /// Last successful connection test date
    var lastConnectionTest: Date?

    /// Whether the last connection test was successful
    var lastConnectionSuccess: Bool = false

    // MARK: - Playback Preferences

    /// Playback mode for Audiobookshelf content
    var playbackMode: AudiobookshelfPlaybackMode = AudiobookshelfPlaybackMode.manualDownload

    // MARK: - Timestamps

    var lastModified: Date = Date()

    // MARK: - Init

    init() {}

    // MARK: - Update Helper

    func touch() {
        lastModified = Date()
    }

    // MARK: - Computed Properties

    /// Get server URL as URL object
    var serverURLObject: URL? {
        guard !serverURL.isEmpty else { return nil }
        return URL(string: serverURL)
    }

    /// Check if server configuration is complete
    var isConfigured: Bool {
        !serverURL.isEmpty
    }

    /// Whether to prefer offline playback (for backwards compatibility with existing code)
    var shouldPreferOffline: Bool {
        playbackMode == .manualDownload || playbackMode == .autoDownload
    }

    /// Whether to auto-download on WiFi
    var shouldAutoDownload: Bool {
        playbackMode == .autoDownload
    }
}
