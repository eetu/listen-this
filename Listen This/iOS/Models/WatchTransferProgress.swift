//
//  WatchTransferProgress.swift
//  Listen This
//
//  Created by Eetu Sutinen on 27.12.2025.
//

import Foundation

// MARK: - Watch Transfer Progress

struct WatchTransferProgress: Equatable {
    let audiobookId: String
    let audiobookTitle: String
    let totalBytes: Int64
    var bytesTransferred: Int64
    var isActive: Bool
    
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
    
    var progressPercentage: Int {
        Int(progress * 100)
    }
    
    var progressText: String {
        let transferred = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(transferred) / \(total)"
    }
}

// MARK: - Transfer Errors
enum WatchTransferError: LocalizedError {
    case sessionUnavailable
    case watchNotAvailable
    case fileNotCached
    case fileNotFound
    case transferFailed
    
    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "Watch Connectivity session is not available"
        case .watchNotAvailable:
            return "Apple Watch is not paired or app is not installed"
        case .fileNotCached:
            return "Audiobook file is not cached on iPhone"
        case .fileNotFound:
            return "Audiobook file could not be found"
        case .transferFailed:
            return "File transfer to Apple Watch failed"
        }
    }
}
