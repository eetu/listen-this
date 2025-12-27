//
//  SyncSettings.swift
//  Listen This
//
//  Manages iCloud sync preferences stored in UserDefaults
//

import Foundation

/// Manages user's sync preferences stored in UserDefaults
@Observable
final class SyncSettings {

    // MARK: - Singleton

    static let shared = SyncSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let syncPlaybackProgress = "syncPlaybackProgress"
        static let lastSyncDate = "lastSyncDate"
    }

    // MARK: - Sync Settings

    /// Whether iCloud sync is enabled
    var iCloudSyncEnabled: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Keys.iCloudSyncEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.iCloudSyncEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.iCloudSyncEnabled)
        }
    }

    /// Whether to sync playback progress across devices
    var syncPlaybackProgress: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Keys.syncPlaybackProgress) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.syncPlaybackProgress)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.syncPlaybackProgress)
        }
    }

    /// Last sync date (updated when sync completes)
    var lastSyncDate: Date? {
        get {
            UserDefaults.standard.object(forKey: Keys.lastSyncDate) as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.lastSyncDate)
        }
    }

    // MARK: - Helpers

    /// Format last sync date for display
    func formattedLastSync() -> String {
        guard let date = lastSyncDate else {
            return "Never"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Mark sync as completed
    func markSyncCompleted() {
        lastSyncDate = Date()
    }

    // MARK: - Init

    private init() {}
}
