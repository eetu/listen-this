//
//  AppLogger.swift
//  Listen This
//
//  Centralized logging using Swift's unified logging system
//

import Foundation
import OSLog

/// Centralized logger for the Listen This app
/// Use subsystem-specific loggers for different components
enum AppLogger {

    /// Subsystem identifier for all app loggers
    private static let subsystem = "com.anarkisti.Listen-This"

    /// Audio playback and player service logging
    static let player = Logger(subsystem: subsystem, category: "AudioPlayer")

    /// Cache management logging
    static let cache = Logger(subsystem: subsystem, category: "CacheManager")

    /// CloudKit sync and transfers
    static let cloudKit = Logger(subsystem: subsystem, category: "CloudKit")

    /// Watch connectivity
    static let watchConnectivity = Logger(subsystem: subsystem, category: "WatchConnectivity")

    /// Import operations
    static let `import` = Logger(subsystem: subsystem, category: "Import")

    /// iCloud Drive operations
    static let iCloudDrive = Logger(subsystem: subsystem, category: "iCloudDrive")

    /// User settings
    static let settings = Logger(subsystem: subsystem, category: "Settings")

    /// General app logging
    static let general = Logger(subsystem: subsystem, category: "General")
}
