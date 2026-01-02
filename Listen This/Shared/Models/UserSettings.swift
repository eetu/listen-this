//
//  UserSettings.swift
//  Listen This
//
//  Central settings model synced via CloudKit across all devices
//

import Foundation
import OSLog
import SwiftData

// MARK: - Sleep Timer Default

/// Represents the default sleep timer setting
enum SleepTimerDefault: Equatable, Codable, CaseIterable {
    case none
    case endOfChapter
    case minutes5
    case minutes10
    case minutes15
    case minutes30
    case minutes45
    case minutes60
    case minutes90
    case minutes120

    /// All available presets for picker UI
    static var allCases: [SleepTimerDefault] {
        [
            .none, .endOfChapter, .minutes5, .minutes10, .minutes15, .minutes30, .minutes45,
            .minutes60, .minutes90, .minutes120,
        ]
    }

    /// Minutes value (nil for none, nil for endOfChapter)
    var minutes: Int? {
        switch self {
        case .none: return nil
        case .endOfChapter: return nil
        case .minutes5: return 5
        case .minutes10: return 10
        case .minutes15: return 15
        case .minutes30: return 30
        case .minutes45: return 45
        case .minutes60: return 60
        case .minutes90: return 90
        case .minutes120: return 120
        }
    }

    /// Raw value for storage (0 = none, -1 = end of chapter, positive = minutes)
    var rawValue: Int {
        switch self {
        case .none: return 0
        case .endOfChapter: return -1
        case .minutes5: return 5
        case .minutes10: return 10
        case .minutes15: return 15
        case .minutes30: return 30
        case .minutes45: return 45
        case .minutes60: return 60
        case .minutes90: return 90
        case .minutes120: return 120
        }
    }

    /// Initialize from raw storage value
    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .none
        case -1: self = .endOfChapter
        case 5: self = .minutes5
        case 10: self = .minutes10
        case 15: self = .minutes15
        case 30: self = .minutes30
        case 45: self = .minutes45
        case 60: self = .minutes60
        case 90: self = .minutes90
        case 120: self = .minutes120
        default: self = .minutes15  // fallback
        }
    }

    /// Format for display
    var displayText: String {
        switch self {
        case .none:
            return "None"
        case .endOfChapter:
            return "End of Chapter"
        case .minutes5: return "5 min"
        case .minutes10: return "10 min"
        case .minutes15: return "15 min"
        case .minutes30: return "30 min"
        case .minutes45: return "45 min"
        case .minutes60: return "1 hour"
        case .minutes90: return "1h 30m"
        case .minutes120: return "2 hours"
        }
    }
}

// MARK: - UserSettings Model

@Model
final class UserSettings {
    // Use a fixed ID so there's only one settings record per user
    var id: String = "user_settings"

    // MARK: - Playback Settings

    /// Whether to remember playback speed per audiobook
    var rememberSpeedPerBook: Bool = true

    /// Skip backward interval in seconds
    var skipBackwardInterval: Int = 15

    /// Skip forward interval in seconds
    var skipForwardInterval: Int = 30

    /// Default sleep timer stored as raw int (0 = none, -1 = end of chapter, positive = minutes)
    var defaultSleepTimerRaw: Int = 0

    // MARK: - Sync Settings

    /// Whether iCloud sync is enabled
    var iCloudSyncEnabled: Bool = true

    /// Whether to sync playback progress across devices
    var syncPlaybackProgress: Bool = true

    // MARK: - Timestamps

    /// Last modification date for conflict resolution
    var lastModified: Date = Date()

    // MARK: - Init

    init() {}

    // MARK: - Update Helper

    /// Update lastModified when any setting changes
    func touch() {
        lastModified = Date()
    }
}

// MARK: - Settings Manager

/// Observable wrapper for accessing UserSettings from SwiftUI views
@Observable
@MainActor
final class SettingsManager {

    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - State

    private(set) var settings: UserSettings?
    private var modelContext: ModelContext?

    // MARK: - Playback Settings

    var rememberSpeedPerBook: Bool {
        get { settings?.rememberSpeedPerBook ?? true }
        set {
            settings?.rememberSpeedPerBook = newValue
            settings?.touch()
            save()
        }
    }

    var skipBackwardInterval: Int {
        get { settings?.skipBackwardInterval ?? 15 }
        set {
            settings?.skipBackwardInterval = newValue
            settings?.touch()
            save()
        }
    }

    var skipForwardInterval: Int {
        get { settings?.skipForwardInterval ?? 30 }
        set {
            settings?.skipForwardInterval = newValue
            settings?.touch()
            save()
        }
    }

    /// Default sleep timer
    var defaultSleepTimer: SleepTimerDefault {
        get { SleepTimerDefault(rawValue: settings?.defaultSleepTimerRaw ?? 0) }
        set {
            settings?.defaultSleepTimerRaw = newValue.rawValue
            settings?.touch()
            save()
        }
    }

    // MARK: - Sync Settings

    var iCloudSyncEnabled: Bool {
        get { settings?.iCloudSyncEnabled ?? true }
        set {
            settings?.iCloudSyncEnabled = newValue
            settings?.touch()
            save()
        }
    }

    var syncPlaybackProgress: Bool {
        get { settings?.syncPlaybackProgress ?? true }
        set {
            settings?.syncPlaybackProgress = newValue
            settings?.touch()
            save()
        }
    }

    // MARK: - Configuration

    /// Configure the manager with a model context (call from app startup)
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadOrCreateSettings()
    }

    // MARK: - Private

    private init() {}

    private func loadOrCreateSettings() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<UserSettings>(
            predicate: #Predicate { $0.id == "user_settings" }
        )

        do {
            let existing = try context.fetch(descriptor)
            if let first = existing.first {
                settings = first
            } else {
                // Create default settings
                let newSettings = UserSettings()
                context.insert(newSettings)
                try context.save()
                settings = newSettings
            }
        } catch {
            AppLogger.settings.error("Failed to load settings: \(error.localizedDescription)")
            // Create in-memory settings as fallback
            settings = UserSettings()
        }
    }

    private func save() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            AppLogger.settings.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Static Presets

    /// Available skip interval presets in seconds
    static let skipIntervalPresets: [Int] = [5, 10, 15, 30, 45, 60, 90]

    /// Format a skip interval for display
    static func formatInterval(_ seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let secs = seconds % 60
            if secs == 0 {
                return "\(minutes) min"
            } else {
                return "\(minutes)m \(secs)s"
            }
        }
        return "\(seconds)s"
    }
}
