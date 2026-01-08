//
//  AudiobookError.swift
//  listen this
//

import Foundation

/// Errors that can occur in the audiobook player
enum AudiobookError: Error {
    // MARK: - Network Errors
    case networkUnavailable
    case authenticationFailed
    case serverUnreachable

    // MARK: - Storage Errors
    case insufficientSpace
    case downloadFailed
    case fileNotFound

    // MARK: - Playback Errors
    case unsupportedFormat
    case corruptedFile
    case playbackFailed

    // MARK: - Sync Errors
    case syncConflict
    case cloudKitUnavailable
    case quotaExceeded

    // MARK: - General Errors
    case unknown(Error)
}

extension AudiobookError: LocalizedError {
    var errorDescription: String? {
        return userMessage
    }

    /// User-friendly error message
    var userMessage: String {
        switch self {
        case .networkUnavailable:
            return "No network connection. Content will download when WiFi is available."
        case .authenticationFailed:
            return "Authentication failed. Please check your credentials."
        case .serverUnreachable:
            return "Cannot reach the server. Please try again later."
        case .insufficientSpace:
            return "Not enough storage. Remove some books to free up space."
        case .fileNotFound:
            return "The audiobook file could not be found."
        case .downloadFailed:
            return "Download failed. Please try again."
        case .unsupportedFormat:
            return "This audiobook format is not supported."
        case .corruptedFile:
            return "The audiobook file appears to be corrupted."
        case .playbackFailed:
            return "Playback failed. Please try again."
        case .syncConflict:
            return "Playback position updated on another device. Using latest position."
        case .cloudKitUnavailable:
            return
                "iCloud Drive is not available. Please enable iCloud Documents in Xcode project settings and ensure you're signed into iCloud on this device."
        case .quotaExceeded:
            return "iCloud storage quota exceeded."
        case .unknown(let error):
            return "An unexpected error occurred: \(error.localizedDescription)"
        }
    }

    /// Whether the error can be recovered from with a retry
    var isRecoverable: Bool {
        switch self {
        case .networkUnavailable, .cloudKitUnavailable, .serverUnreachable, .downloadFailed:
            return true  // Can retry later
        case .unsupportedFormat, .corruptedFile:
            return false  // Permanent failure
        case .authenticationFailed, .quotaExceeded:
            return false  // Requires user action
        default:
            return true
        }
    }
}

/// Error for cache-related operations
enum CacheError: Error {
    case insufficientSpace
    case cleanupFailed
    case invalidPath
    case fileOperationFailed
}

extension CacheError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .insufficientSpace:
            return "Not enough storage space available for caching."
        case .cleanupFailed:
            return "Failed to clean up cache storage."
        case .invalidPath:
            return "Invalid cache file path."
        case .fileOperationFailed:
            return "File operation failed."
        }
    }
}
