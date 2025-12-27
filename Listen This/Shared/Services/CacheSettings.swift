//
//  CacheSettings.swift
//  Listen This
//
//  Manages cache preferences stored in UserDefaults
//

import Foundation

/// Manages user's cache preferences stored in UserDefaults
@Observable
final class CacheSettings {

    // MARK: - Singleton

    static let shared = CacheSettings()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let maxCacheSizeGB = "maxCacheSizeGB"
        static let keepRecentCount = "keepRecentCount"
        static let autoCleanupEnabled = "autoCleanupEnabled"
    }

    // MARK: - Cache Size

    /// Maximum cache size in GB
    var maxCacheSizeGB: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Keys.maxCacheSizeGB)
            return stored > 0 ? stored : 3.0  // Default 3GB
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.maxCacheSizeGB)
        }
    }

    /// Maximum cache size in bytes
    var maxCacheSizeBytes: Int64 {
        Int64(maxCacheSizeGB * 1_000_000_000)
    }

    /// Available cache size presets in GB
    static let cacheSizePresets: [Double] = [1.0, 2.0, 3.0, 5.0, 10.0, 20.0]

    // MARK: - Keep Recent

    /// Number of recent audiobooks to keep cached
    var keepRecentCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.keepRecentCount)
            return stored > 0 ? stored : 5  // Default 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.keepRecentCount)
        }
    }

    /// Available keep recent count presets
    static let keepRecentPresets: [Int] = [3, 5, 10, 15, 20]

    // MARK: - Auto Cleanup

    /// Whether automatic cache cleanup is enabled
    var autoCleanupEnabled: Bool {
        get {
            // Default to true if not set
            if UserDefaults.standard.object(forKey: Keys.autoCleanupEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.autoCleanupEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoCleanupEnabled)
        }
    }

    // MARK: - Helpers

    /// Format cache size for display
    static func formatCacheSize(_ gb: Double) -> String {
        if gb == Double(Int(gb)) {
            return "\(Int(gb)) GB"
        } else {
            return String(format: "%.1f GB", gb)
        }
    }

    /// Format bytes for display
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Init

    private init() {}
}
