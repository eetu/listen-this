//
//  TransferProgressCenter.swift
//  Listen This
//
//  One place for library rows to read "how far along is this book's transfer",
//  whichever route is carrying it.
//

import Foundation
import Observation

/// Publishes transfer completion fractions so UI that isn't driving a transfer
/// can still display it.
///
/// `AudiobookshelfDownloadManager` is a singleton a row could observe directly,
/// but `CloudKitChunkedTransferManager` is created per use — once its sheet is
/// dismissed there is no instance for a row to watch. Both report here instead,
/// so a row needs to know about neither.
@MainActor
@Observable
final class TransferProgressCenter {

    static let shared = TransferProgressCenter()

    /// Completion fraction (0...1) per audiobook, present only while active.
    private(set) var fractions: [UUID: Double] = [:]

    private init() {}

    func report(_ audiobookId: UUID, fraction: Double) {
        guard fraction.isFinite else { return }
        fractions[audiobookId] = min(max(fraction, 0), 1)
    }

    /// Report from a byte count, ignoring updates where the total isn't known
    /// yet rather than showing a misleading zero.
    func report(_ audiobookId: UUID, bytesTransferred: Int64, totalBytes: Int64) {
        guard totalBytes > 0 else { return }
        report(audiobookId, fraction: Double(bytesTransferred) / Double(totalBytes))
    }

    func finish(_ audiobookId: UUID) {
        fractions.removeValue(forKey: audiobookId)
    }

    func fraction(for audiobookId: UUID) -> Double? {
        fractions[audiobookId]
    }
}
