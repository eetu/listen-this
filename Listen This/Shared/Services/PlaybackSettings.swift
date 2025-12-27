//
//  PlaybackSettings.swift
//  Listen This
//
//  Manages persistent playback preferences across the app
//

import Foundation

/// Manages user's playback preferences stored in UserDefaults
@Observable
final class PlaybackSettings {

    // MARK: - Singleton

    static let shared = PlaybackSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let defaultPlaybackSpeed = "defaultPlaybackSpeed"
        static let skipBackwardInterval = "skipBackwardInterval"
        static let skipForwardInterval = "skipForwardInterval"
        static let defaultSleepTimerMinutes = "defaultSleepTimerMinutes"
        static let rememberSpeedPerBook = "rememberSpeedPerBook"
    }

    // MARK: - Playback Speed

    /// Default playback speed (0.5 - 3.0)
    var defaultPlaybackSpeed: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Keys.defaultPlaybackSpeed)
            return stored > 0 ? stored : 1.0
        }
        set {
            let clamped = min(max(newValue, 0.5), 3.0)
            UserDefaults.standard.set(clamped, forKey: Keys.defaultPlaybackSpeed)
        }
    }

    /// Whether to remember playback speed per audiobook
    var rememberSpeedPerBook: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Keys.rememberSpeedPerBook) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.rememberSpeedPerBook)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.rememberSpeedPerBook)
        }
    }

    /// Available playback speed presets
    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    // MARK: - Skip Intervals

    /// Skip backward interval in seconds
    var skipBackwardInterval: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.skipBackwardInterval)
            return stored > 0 ? stored : 15
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.skipBackwardInterval)
        }
    }

    /// Skip forward interval in seconds
    var skipForwardInterval: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.skipForwardInterval)
            return stored > 0 ? stored : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.skipForwardInterval)
        }
    }

    /// Available skip interval presets in seconds
    static let skipIntervalPresets: [Int] = [5, 10, 15, 30, 45, 60, 90]

    // MARK: - Sleep Timer

    /// Special value for "End of Chapter" sleep timer
    static let sleepTimerEndOfChapter = -1

    /// Default sleep timer duration in minutes (0 = no default, -1 = end of chapter)
    var defaultSleepTimerMinutes: Int {
        get {
            UserDefaults.standard.integer(forKey: Keys.defaultSleepTimerMinutes)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.defaultSleepTimerMinutes)
        }
    }

    /// Available sleep timer presets in minutes (0 = none, -1 = end of chapter)
    static let sleepTimerPresets: [Int] = [0, -1, 5, 10, 15, 30, 45, 60, 90, 120]

    // MARK: - Helpers

    /// Format a speed value for display
    static func formatSpeed(_ speed: Double) -> String {
        if speed == Double(Int(speed)) {
            return "\(Int(speed))x"
        } else {
            return String(format: "%.2gx", speed)
        }
    }

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

    /// Format sleep timer for display
    static func formatSleepTimer(_ minutes: Int) -> String {
        if minutes == 0 {
            return "None"
        } else if minutes == sleepTimerEndOfChapter {
            return "End of Chapter"
        } else if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours) hour\(hours > 1 ? "s" : "")"
            } else {
                return "\(hours)h \(mins)m"
            }
        }
        return "\(minutes) min"
    }

    // MARK: - Init

    private init() {}
}
