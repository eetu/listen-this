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
    /// Exponential moving average of recent throughput, so the displayed speed
    /// reflects current conditions and recovers after a stall instead of being
    /// dragged down by a lifetime average.
    var smoothedSpeedBytesPerSecond: Double
    /// Set when the transfer finishes so the completion screen can show a true
    /// average over the actual transfer duration.
    var completedTime: Date?

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
        self.lastBytesTransferred = bytesTransferred
        self.smoothedSpeedBytesPerSecond = 0
        self.completedTime = nil
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
    
    /// Current transfer speed in bytes per second, smoothed over recent activity.
    /// Falls back to the lifetime average only before the first windowed sample.
    var currentSpeedBytesPerSecond: Double {
        if smoothedSpeedBytesPerSecond > 0 { return smoothedSpeedBytesPerSecond }
        let elapsed = lastUpdateTime.timeIntervalSince(startTime)
        guard elapsed > 0 else { return 0 }
        return Double(bytesTransferred) / elapsed
    }

    /// True average speed over the whole transfer, for the completion summary.
    var averageSpeedBytesPerSecond: Double {
        let elapsed = (completedTime ?? lastUpdateTime).timeIntervalSince(startTime)
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

    /// Formatted average speed string for the completion summary
    var averageSpeedText: String {
        let speed = averageSpeedBytesPerSecond
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
    
    /// Update bytes transferred and refresh timing for speed calculation.
    /// Computes an instantaneous rate from the delta since the last update and
    /// folds it into an exponential moving average.
    mutating func updateProgress(bytesTransferred: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdateTime)
        let deltaBytes = bytesTransferred - self.bytesTransferred
        if dt > 0, deltaBytes > 0 {
            let instantaneous = Double(deltaBytes) / dt
            // Smoothing factor: weight recent samples but keep some history.
            let alpha = 0.3
            smoothedSpeedBytesPerSecond = smoothedSpeedBytesPerSecond > 0
                ? alpha * instantaneous + (1 - alpha) * smoothedSpeedBytesPerSecond
                : instantaneous
        }
        self.lastBytesTransferred = self.bytesTransferred
        self.bytesTransferred = bytesTransferred
        self.lastUpdateTime = now
    }

    /// Mark the transfer as finished, stamping completion time and full progress.
    mutating func markCompleted() {
        bytesTransferred = totalBytes
        completedTime = Date()
        isActive = false
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
