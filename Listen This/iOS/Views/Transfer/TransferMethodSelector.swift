//
//  TransferMethodSelector.swift
//  Listen This
//
//  Smart selector that chooses the best transfer method
//  based on file size, network conditions, and user preferences
//

import Foundation
import Network
import OSLog
import SwiftData
import SwiftUI

/// Selects optimal transfer method based on conditions
@MainActor
@Observable
final class TransferMethodSelector {

    // MARK: - Configuration

    /// File size threshold for choosing CloudKit (50MB)
    static let cloudKitThreshold: Int64 = 50 * 1024 * 1024

    /// Maximum file size for WatchConnectivity (300MB)
    static let watchConnectivityLimit: Int64 = 300 * 1024 * 1024

    // MARK: - Properties

    private let modelContext: ModelContext
    private let cloudKitManager: CloudKitChunkedTransferManager

    #if os(iOS)
        private let watchConnectivityManager: iOSWatchConnectivityManager
    #endif

    private let networkMonitor = NWPathMonitor()
    private var currentNetworkStatus: NetworkStatus = .unknown

    // MARK: - User Preferences

    var preferredMethod: TransferMethod {
        get {
            if let stored = UserDefaults.standard.string(forKey: "preferredTransferMethod"),
                let method = TransferMethod(rawValue: stored)
            {
                return method
            }
            return .automatic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredTransferMethod")
        }
    }

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.cloudKitManager = CloudKitChunkedTransferManager(modelContext: modelContext)

        #if os(iOS)
            self.watchConnectivityManager = iOSWatchConnectivityManager.shared
        #endif

        startNetworkMonitoring()
    }

    // MARK: - Transfer Method Selection

    /// Determine the best transfer method for an audiobook
    func selectMethod(for audiobook: Audiobook) async -> SelectedMethod {
        // Check if already uploaded to CloudKit
        let cloudKitStatus = await cloudKitManager.checkCloudKitChunks(for: audiobook)

        if cloudKitStatus == .fullyUploaded {
            return .alreadyUploaded(reason: "It was uploaded earlier.")
        }

        let preference = "Your choice in Transfer settings."
        switch preferredMethod {
        case .automatic:
            return automaticSelection(for: audiobook)
        case .cloudKit:
            return .cloudKit(reason: preference)
        case .watchConnectivity:
            #if os(iOS)
                return .watchConnectivity(reason: preference)
            #else
                return .cloudKit(reason: "WatchConnectivity unavailable on Watch")
            #endif
        case .iCloudDirect:
            return .iCloudDirect(reason: preference)
        }
    }

    /// Automatic selection based on file size and conditions
    private func automaticSelection(for audiobook: Audiobook) -> SelectedMethod {
        let fileSize = audiobook.fileSize

        // The monitor's first callback can arrive after this runs; read the
        // path directly rather than decide on an unknown network.
        updateNetworkStatus(networkMonitor.currentPath)

        // Very large files (>300MB) - CloudKit only
        if fileSize > Self.watchConnectivityLimit {
            return .cloudKit(reason: "Picked because the book is too large to send directly.")
        }

        // Large files (>50MB) - prefer CloudKit
        if fileSize > Self.cloudKitThreshold {
            // Check network status
            switch currentNetworkStatus {
            case .wifi:
                return .cloudKit(reason: "Picked because it's faster for a large book on Wi-Fi.")
            case .cellular:
                #if os(iOS)
                    return .watchConnectivity(
                        reason: "Picked because this iPhone isn't on Wi-Fi.")
                #else
                    return .cloudKit(reason: "Large file + cellular Watch")
                #endif
            case .none, .unknown:
                #if os(iOS)
                    return .watchConnectivity(
                        reason: "Picked because this iPhone is offline.")
                #else
                    return .error(reason: "No network connection available")
                #endif
            }
        }

        // Small files (<50MB)
        #if os(iOS)
            // On iPhone, use WatchConnectivity for small files if Watch is nearby
            if watchConnectivityManager.isReachable {
                return .watchConnectivity(
                    reason: "Picked because the book is small and the Watch is reachable.")
            } else {
                return .cloudKit(reason: "Picked because the Watch isn't reachable right now.")
            }
        #else
            // On Watch, always use CloudKit for downloads
            return .cloudKit(reason: "Watch downloading from cloud")
        #endif
    }

    // MARK: - Transfer Execution

    /// Execute transfer using selected method
    func transfer(_ audiobook: Audiobook) async throws {
        let method = await selectMethod(for: audiobook)

        AppLogger.general.info("Using \(method.description) for \(audiobook.title)")

        switch method {
        case .cloudKit(let reason):
            AppLogger.general.debug("Reason: \(reason)")
            try await transferViaCloudKit(audiobook)

        case .watchConnectivity(let reason):
            AppLogger.general.debug("Reason: \(reason)")
            #if os(iOS)
                try await transferViaWatchConnectivity(audiobook)
            #else
                throw TransferError.methodUnavailable
            #endif

        case .iCloudDirect(let reason):
            AppLogger.general.debug("Reason: \(reason)")
            try await downloadFromiCloud(audiobook)

        case .alreadyUploaded(let reason):
            AppLogger.general.debug("Already uploaded: \(reason)")
            // Nothing to do - book is already in CloudKit
            return

        case .error(let reason):
            throw TransferError.noMethodAvailable(reason)
        }
    }

    // MARK: - Transfer Implementations

    private func transferViaCloudKit(_ audiobook: Audiobook) async throws {
        #if os(iOS)
            // iPhone: Upload to CloudKit
            try await cloudKitManager.uploadAudiobook(audiobook)
        #else
            // Watch: Download from CloudKit
            let outputURL = try await cloudKitManager.downloadAudiobook(audiobook)
            AppLogger.cloudKit.info("Downloaded to: \(outputURL.path)")
        #endif
    }

    #if os(iOS)
        private func transferViaWatchConnectivity(_ audiobook: Audiobook) async throws {
            // Ensure file is cached first
            if !audiobook.isFileCached {
                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                _ = try await audiobook.downloadAndCache(using: cacheManager)
            }

            // Transfer to Watch
            try await watchConnectivityManager.transferAudiobook(audiobook)
        }
    #endif

    private func downloadFromiCloud(_ audiobook: Audiobook) async throws {
        let cacheManager = AudiobookCacheManager(modelContext: modelContext)
        _ = try await audiobook.downloadAndCache(using: cacheManager)
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateNetworkStatus(path)
            }
        }

        let queue = DispatchQueue(label: "NetworkMonitor")
        networkMonitor.start(queue: queue)
    }

    private func updateNetworkStatus(_ path: NWPath) {
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) {
                currentNetworkStatus = .wifi
            } else if path.usesInterfaceType(.cellular) {
                currentNetworkStatus = .cellular
            } else {
                currentNetworkStatus = .unknown
            }
        } else {
            currentNetworkStatus = .none
        }
    }

    deinit {
        networkMonitor.cancel()
    }
}

// MARK: - Supporting Types

enum TransferMethod: String, CaseIterable, Identifiable {
    case automatic = "automatic"
    case cloudKit = "cloudkit"
    case watchConnectivity = "watchconnectivity"
    case iCloudDirect = "iclouddirect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .cloudKit:
            return "Via iCloud"
        case .watchConnectivity:
            return "Directly from iPhone"
        case .iCloudDirect:
            return "iCloud Drive"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            return "Picks the best route for each book"
        case .cloudKit:
            return "Uploads to iCloud, then the Watch downloads it. Faster for large books"
        case .watchConnectivity:
            return "Sends straight to the Watch. Slower, uses no iCloud storage"
        case .iCloudDirect:
            return "Download directly from iCloud Drive"
        }
    }
}

enum SelectedMethod: CustomStringConvertible {
    case cloudKit(reason: String)
    case watchConnectivity(reason: String)
    case iCloudDirect(reason: String)
    case alreadyUploaded(reason: String)
    case error(reason: String)

    /// Why this route was picked, for display. An error's reason is its whole
    /// message, so it has none of its own.
    var reason: String? {
        switch self {
        case .cloudKit(let reason), .watchConnectivity(let reason),
            .iCloudDirect(let reason), .alreadyUploaded(let reason):
            reason
        case .error:
            nil
        }
    }

    var description: String {
        switch self {
        case .cloudKit(let reason):
            return "CloudKit (\(reason))"
        case .watchConnectivity(let reason):
            return "WatchConnectivity (\(reason))"
        case .iCloudDirect(let reason):
            return "iCloud Direct (\(reason))"
        case .alreadyUploaded(let reason):
            return "Already Uploaded (\(reason))"
        case .error(let reason):
            return "Error: \(reason)"
        }
    }
}

enum NetworkStatus {
    case wifi
    case cellular
    case none
    case unknown
}

enum TransferError: LocalizedError {
    case methodUnavailable
    case noMethodAvailable(String)

    var errorDescription: String? {
        switch self {
        case .methodUnavailable:
            return "Selected transfer method is not available on this device"
        case .noMethodAvailable(let reason):
            return "No transfer method available: \(reason)"
        }
    }
}
