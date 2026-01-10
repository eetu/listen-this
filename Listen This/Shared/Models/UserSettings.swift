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

    // MARK: - Transfer Settings

    /// Whether to allow cellular data for CloudKit chunk transfers
    /// Default is false (WiFi-only) to preserve battery and avoid data charges
    var allowCellularForCloudKitTransfers: Bool = false

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
    private(set) var audiobookshelfSettings: AudiobookshelfSettings?
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

    // MARK: - Transfer Settings

    var allowCellularForCloudKitTransfers: Bool {
        get { settings?.allowCellularForCloudKitTransfers ?? false }
        set {
            settings?.allowCellularForCloudKitTransfers = newValue
            settings?.touch()
            save()
        }
    }

    // MARK: - Audiobookshelf Settings

    /// Audiobookshelf server URL
    var audiobookshelfServerURL: String {
        get {
            let url = audiobookshelfSettings?.serverURL ?? ""
            if audiobookshelfSettings == nil {
                AppLogger.settings.warning("audiobookshelfSettings is nil, returning empty string")
            } else if url.isEmpty {
                AppLogger.settings.warning("audiobookshelfSettings.serverURL is empty")
            }
            return url
        }
        set {
            audiobookshelfSettings?.serverURL = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Audiobookshelf API key
    var audiobookshelfAPIKey: String {
        get { audiobookshelfSettings?.apiKey ?? "" }
        set {
            audiobookshelfSettings?.apiKey = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Whether Audiobookshelf integration is enabled
    var audiobookshelfEnabled: Bool {
        get { audiobookshelfSettings?.isEnabled ?? false }
        set {
            audiobookshelfSettings?.isEnabled = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Playback mode for Audiobookshelf
    var audiobookshelfPlaybackMode: AudiobookshelfPlaybackMode {
        get { audiobookshelfSettings?.playbackMode ?? .manualDownload }
        set {
            audiobookshelfSettings?.playbackMode = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Last connection test date
    var audiobookshelfLastConnectionTest: Date? {
        get { audiobookshelfSettings?.lastConnectionTest }
        set {
            audiobookshelfSettings?.lastConnectionTest = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Last connection success status
    var audiobookshelfLastConnectionSuccess: Bool {
        get { audiobookshelfSettings?.lastConnectionSuccess ?? false }
        set {
            audiobookshelfSettings?.lastConnectionSuccess = newValue
            audiobookshelfSettings?.touch()
            save()
        }
    }

    /// Check if Audiobookshelf is configured
    var audiobookshelfIsConfigured: Bool {
        audiobookshelfSettings?.isConfigured ?? false
    }

    // MARK: - Configuration

    /// Configure the manager with a model context (call from app startup)
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadOrCreateSettings()
        loadOrCreateAudiobookshelfSettings()
    }

    /// Refresh settings from database without saving (used for CloudKit sync notifications)
    func refreshSettings() {
        guard let context = modelContext else { return }

        // Reload UserSettings
        let userDescriptor = FetchDescriptor<UserSettings>(
            predicate: #Predicate { $0.id == "user_settings" }
        )
        if let userSettings = try? context.fetch(userDescriptor).first {
            // Only log if settings changed
            if settings?.lastModified != userSettings.lastModified {
                AppLogger.settings.info("[SettingsManager] UserSettings changed via CloudKit sync")
            }
            settings = userSettings
        }

        // Reload AudiobookshelfSettings
        let absDescriptor = FetchDescriptor<AudiobookshelfSettings>(
            predicate: #Predicate { $0.id == "audiobookshelf_settings" }
        )
        if let absSettings = try? context.fetch(absDescriptor).first {
            // Only log if settings changed
            if audiobookshelfSettings?.lastModified != absSettings.lastModified {
                AppLogger.settings.info(
                    "[SettingsManager] AudiobookshelfSettings changed via CloudKit sync - serverURL: '\(absSettings.serverURL)'"
                )
            }
            audiobookshelfSettings = absSettings
        }
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

    func loadOrCreateAudiobookshelfSettings() {
        guard let context = modelContext else {
            AppLogger.settings.error("No model context available for Audiobookshelf settings")
            return
        }

        // Debug: Check all records
        let allDescriptor = FetchDescriptor<AudiobookshelfSettings>()
        do {
            let allSettings = try context.fetch(allDescriptor)
            AppLogger.settings.info(
                "[SettingsManager] Found \(allSettings.count) AudiobookshelfSettings record(s) in total"
            )
            for (index, setting) in allSettings.enumerated() {
                AppLogger.settings.info(
                    "[SettingsManager] Record \(index): id='\(setting.id)', serverURL='\(setting.serverURL)', enabled=\(setting.isEnabled)"
                )
            }
        } catch {
            AppLogger.settings.error(
                "Failed to fetch all settings: \(error.localizedDescription)")
        }

        let descriptor = FetchDescriptor<AudiobookshelfSettings>(
            predicate: #Predicate { $0.id == "audiobookshelf_settings" }
        )

        do {
            let existing = try context.fetch(descriptor)
            if let first = existing.first {
                AppLogger.settings.info(
                    "[SettingsManager] Loaded existing Audiobookshelf settings - serverURL: '\(first.serverURL)', enabled: \(first.isEnabled)"
                )
                audiobookshelfSettings = first

                // Clean up any duplicate records (keep the one with most recent lastModified)
                if existing.count > 1 {
                    AppLogger.settings.warning(
                        "[SettingsManager] Found \(existing.count) AudiobookshelfSettings records, cleaning up duplicates"
                    )

                    // Find the most recently modified record
                    let mostRecent = existing.max(by: { $0.lastModified < $1.lastModified })

                    // Delete all others
                    for setting in existing where setting !== mostRecent {
                        AppLogger.settings.info(
                            "[SettingsManager] Deleting duplicate record - serverURL: '\(setting.serverURL)', lastModified: \(setting.lastModified)"
                        )
                        context.delete(setting)
                    }

                    // Use the most recent one
                    if let mostRecent = mostRecent {
                        audiobookshelfSettings = mostRecent
                        AppLogger.settings.info(
                            "[SettingsManager] Using most recent record - serverURL: '\(mostRecent.serverURL)', lastModified: \(mostRecent.lastModified)"
                        )
                    }

                    try context.save()
                }
            } else {
                #if os(iOS)
                    // iOS: Create default Audiobookshelf settings if none exist
                    AppLogger.settings.info(
                        "[SettingsManager] Creating new Audiobookshelf settings with default values"
                    )
                    let newSettings = AudiobookshelfSettings()
                    context.insert(newSettings)
                    try context.save()
                    audiobookshelfSettings = newSettings
                #else
                    // Watch: Don't create settings, wait for sync from iPhone
                    AppLogger.settings.info(
                        "[SettingsManager] No settings found - waiting for sync from iPhone")
                    audiobookshelfSettings = nil
                #endif
            }
        } catch {
            #if os(iOS)
                AppLogger.settings.error(
                    "[SettingsManager] Failed to load Audiobookshelf settings: \(error.localizedDescription)"
                )
                // Create in-memory settings as fallback on iOS only
                audiobookshelfSettings = AudiobookshelfSettings()
            #else
                AppLogger.settings.error(
                    "[SettingsManager] Failed to load Audiobookshelf settings: \(error.localizedDescription)"
                )
                // Watch: Don't create fallback, wait for sync
                audiobookshelfSettings = nil
            #endif
        }
    }

    private func save() {
        guard let context = modelContext else {
            AppLogger.settings.error("Cannot save settings: no model context")
            return
        }
        do {
            if let abs = audiobookshelfSettings {
                AppLogger.settings.info(
                    "Saving Audiobookshelf settings - serverURL: '\(abs.serverURL)', enabled: \(abs.isEnabled)"
                )
            }
            try context.save()
            AppLogger.settings.info("Settings saved successfully to SwiftData/CloudKit")
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
