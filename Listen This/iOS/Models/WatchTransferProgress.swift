//
//  WatchTransferProgress.swift
//  Listen This
//

import Foundation

// MARK: - Watch Transfer Progress

struct WatchTransferProgress: Equatable {
    let audiobookId: String
    let audiobookTitle: String
    let totalBytes: Int64
    var bytesTransferred: Int64
    var isActive: Bool
    
    // Speed tracking
    var startTime: Date
    var lastUpdateTime: Date
    var lastBytesTransferred: Int64
    
    init(
        audiobookId: String,
        audiobookTitle: String,
        totalBytes: Int64,
        bytesTransferred: Int64 = 0,
        isActive: Bool = true
    ) {
        self.audiobookId = audiobookId
        self.audiobookTitle = audiobookTitle
        self.totalBytes = totalBytes
        self.bytesTransferred = bytesTransferred
        self.isActive = isActive
        self.startTime = Date()
        self.lastUpdateTime = Date()
        self.lastBytesTransferred = 0
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    var progressPercentage: Int {
        Int(progress * 100)
    }

    var progressText: String {
        let transferred = ByteCountFormatter.string(
            fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(transferred) / \(total)"
    }
    
    /// Current transfer speed in bytes per second (based on recent activity)
    var currentSpeedBytesPerSecond: Double {
        let elapsed = lastUpdateTime.timeIntervalSince(startTime)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred) / elapsed
    }
    
    /// Formatted transfer speed string
    var speedText: String {
        let speed = currentSpeedBytesPerSecond
        guard speed > 0 else { return "" }
        let speedFormatted = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
        return "\(speedFormatted)/s"
    }
    
    /// Estimated time remaining
    var estimatedTimeRemaining: TimeInterval? {
        let speed = currentSpeedBytesPerSecond
        guard speed > 0 else { return nil }
        let remainingBytes = totalBytes - bytesTransferred
        return Double(remainingBytes) / speed
    }
    
    /// Formatted estimated time remaining
    var estimatedTimeRemainingText: String? {
        guard let remaining = estimatedTimeRemaining, remaining > 0, remaining.isFinite else { return nil }
        
        if remaining < 60 {
            return "< 1 min remaining"
        } else if remaining < 3600 {
            let minutes = Int(remaining / 60)
            return "\(minutes) min remaining"
        } else {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes > 0 {
                return "\(hours)h \(minutes)m remaining"
            } else {
                return "\(hours)h remaining"
            }
        }
    }
    
    /// Update bytes transferred and refresh timing for speed calculation
    mutating func updateProgress(bytesTransferred: Int64) {
        self.lastBytesTransferred = self.bytesTransferred
        self.bytesTransferred = bytesTransferred
        self.lastUpdateTime = Date()
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
