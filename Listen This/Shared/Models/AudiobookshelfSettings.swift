//
//  AudiobookshelfSettings.swift
//  Listen This
//
//  Model for storing Audiobookshelf server configuration
//

import Foundation
import OSLog
import SwiftData

@Model
final class AudiobookshelfSettings {
    // Use a fixed ID so there's only one Audiobookshelf settings record per user
    var id: String = "audiobookshelf_settings"

    // MARK: - Server Configuration

    /// Server URL (e.g., "http://192.168.1.69:13378")
    var serverURL: String = ""

    /// Whether Audiobookshelf integration is enabled
    var isEnabled: Bool = false

    /// Last successful connection test date
    var lastConnectionTest: Date?

    /// Whether the last connection test was successful
    var lastConnectionSuccess: Bool = false

    // MARK: - Playback Preferences

    /// Prefer downloading books for offline playback (vs streaming)
    var preferOfflinePlayback: Bool = true

    /// Automatically download books when on WiFi
    var autoDownloadOnWiFi: Bool = false

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
}
