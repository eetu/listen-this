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
        static let skipBackwardInterval = "skipBackwardInterval"
        static let skipForwardInterval = "skipForwardInterval"
        static let defaultSleepTimerMinutes = "defaultSleepTimerMinutes"
        static let rememberSpeedPerBook = "rememberSpeedPerBook"
    }

    // MARK: - Stored Properties (for @Observable tracking)

    private var _rememberSpeedPerBook: Bool
    private var _skipBackwardInterval: Int
    private var _skipForwardInterval: Int
    private var _defaultSleepTimerMinutes: Int

    // MARK: - Playback Speed

    /// Whether to remember playback speed per audiobook
    var rememberSpeedPerBook: Bool {
        get { _rememberSpeedPerBook }
        set {
            _rememberSpeedPerBook = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.rememberSpeedPerBook)
        }
    }

    // MARK: - Skip Intervals

    /// Skip backward interval in seconds
    var skipBackwardInterval: Int {
        get { _skipBackwardInterval }
        set {
            _skipBackwardInterval = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.skipBackwardInterval)
        }
    }

    /// Skip forward interval in seconds
    var skipForwardInterval: Int {
        get { _skipForwardInterval }
        set {
            _skipForwardInterval = newValue
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
        get { _defaultSleepTimerMinutes }
        set {
            _defaultSleepTimerMinutes = newValue
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

    private init() {
        // Load from UserDefaults with defaults
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Keys.rememberSpeedPerBook) == nil {
            _rememberSpeedPerBook = true
        } else {
            _rememberSpeedPerBook = defaults.bool(forKey: Keys.rememberSpeedPerBook)
        }

        let storedBackward = defaults.integer(forKey: Keys.skipBackwardInterval)
        _skipBackwardInterval = storedBackward > 0 ? storedBackward : 15

        let storedForward = defaults.integer(forKey: Keys.skipForwardInterval)
        _skipForwardInterval = storedForward > 0 ? storedForward : 30

        _defaultSleepTimerMinutes = defaults.integer(forKey: Keys.defaultSleepTimerMinutes)
    }
}
