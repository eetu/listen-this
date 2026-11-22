//
//  WatchCloudKitDownloads.swift
//  Listen This Watch App
//
//  Owns the Watch's iCloud (CloudKit chunk) downloads, so one the iPhone asked
//  for starts on its own and keeps running when its sheet is closed.
//

import Foundation
import Observation
import OSLog
import SwiftData
import WatchKit

@MainActor
@Observable
final class WatchCloudKitDownloads {

    static let shared = WatchCloudKitDownloads()

    /// Below this charge an unattended download waits for the user, who can
    /// still start it by hand.
    static let minimumBatteryLevel: Float = 0.2

    /// How long a request waits for its book to sync to the Watch before it is
    /// dropped. Covers a book deleted on the iPhone in the meantime.
    static let pendingLifetime: TimeInterval = 7 * 24 * 60 * 60

    struct Failure {
        let audiobookId: UUID
        let title: String
        let message: String
    }

    /// The book that most recently failed to download unattended.
    var failure: Failure?

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private let logger = AppLogger.cloudKit
    private var manager: CloudKitChunkedTransferManager?

    private static let pendingKey = "cloudKit.pendingAutoDownloads"

    private init() {}

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        manager = CloudKitChunkedTransferManager(modelContext: modelContext)
    }

    /// One manager for every iCloud download, so the manual download screen
    /// sees (and can cancel) a download that started on its own.
    func transferManager(modelContext: ModelContext) -> CloudKitChunkedTransferManager {
        configure(modelContext: modelContext)
        return manager ?? CloudKitChunkedTransferManager(modelContext: modelContext)
    }

    func isDownloading(_ audiobookId: UUID) -> Bool {
        manager?.activeDownloads[audiobookId] != nil
    }

    /// CloudKit operations need the app in front: they don't survive suspension.
    func setAppActive(_ isActive: Bool) {
        isAppActive = isActive
        if isActive { startPending() }
    }

    // MARK: - Requests from iPhone

    /// Also the retry after a failure: queue it again and start if possible.
    func uploadReady(audiobookId: UUID) {
        var pending = pendingRequests
        pending[audiobookId.uuidString] = Date()
        pendingRequests = pending
        startPending()
    }

    /// Start every queued download whose book is on the Watch. Called when a
    /// request arrives and whenever the app comes to the front.
    func startPending() {
        guard isAppActive, let modelContext, let manager else { return }

        var pending = pendingRequests
        defer { pendingRequests = pending }

        for (key, requested) in pending {
            guard let id = UUID(uuidString: key),
                Date().timeIntervalSince(requested) < Self.pendingLifetime
            else {
                pending.removeValue(forKey: key)
                continue
            }

            let descriptor = FetchDescriptor<Audiobook>(predicate: #Predicate { $0.id == id })
            guard let audiobook = try? modelContext.fetch(descriptor).first else {
                // Not synced to the Watch yet; try again later
                continue
            }

            if audiobook.isFileCached || manager.activeDownloads[id] != nil {
                pending.removeValue(forKey: key)
                continue
            }

            guard batteryAllowsUnattendedDownload else {
                logger.info("Battery low; leaving '\(audiobook.title)' for the user to start")
                return
            }

            pending.removeValue(forKey: key)
            start(audiobook, using: manager)
        }
    }

    private func start(_ audiobook: Audiobook, using manager: CloudKitChunkedTransferManager) {
        let id = audiobook.id
        let title = audiobook.title
        logger.info("Starting iCloud download of '\(title)' requested by iPhone")

        Task {
            do {
                _ = try await manager.downloadAudiobook(audiobook)
                WKInterfaceDevice.current().play(.success)
                WatchConnectivityManager.shared.sendCachedAudiobookList()
            } catch ChunkTransferError.cancelled {
                // The user stopped it
            } catch ChunkTransferError.alreadyInProgress {
                // Started by hand in the meantime
            } catch {
                WKInterfaceDevice.current().play(.failure)
                failure = Failure(
                    audiobookId: id, title: title, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private var batteryAllowsUnattendedDownload: Bool {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        switch device.batteryState {
        case .charging, .full:
            return true
        default:
            // An unknown level reads as negative; don't block on it
            return device.batteryLevel < 0 || device.batteryLevel >= Self.minimumBatteryLevel
        }
    }

    private var pendingRequests: [String: Date] {
        get {
            UserDefaults.standard.dictionary(forKey: Self.pendingKey) as? [String: Date] ?? [:]
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.pendingKey)
            }
        }
    }
}
