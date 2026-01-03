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
    func selectMethod(for audiobook: Audiobook) -> SelectedMethod {
        switch preferredMethod {
        case .automatic:
            return automaticSelection(for: audiobook)
        case .cloudKit:
            return .cloudKit(reason: "User preference")
        case .watchConnectivity:
            #if os(iOS)
                return .watchConnectivity(reason: "User preference")
            #else
                return .cloudKit(reason: "WatchConnectivity unavailable on Watch")
            #endif
        case .iCloudDirect:
            return .iCloudDirect(reason: "User preference")
        }
    }

    /// Automatic selection based on file size and conditions
    private func automaticSelection(for audiobook: Audiobook) -> SelectedMethod {
        let fileSize = audiobook.fileSize

        // Very large files (>300MB) - CloudKit only
        if fileSize > Self.watchConnectivityLimit {
            return .cloudKit(reason: "File too large for WatchConnectivity")
        }

        // Large files (>50MB) - prefer CloudKit
        if fileSize > Self.cloudKitThreshold {
            // Check network status
            switch currentNetworkStatus {
            case .wifi:
                return .cloudKit(reason: "Large file + WiFi available")
            case .cellular:
                #if os(iOS)
                    return .watchConnectivity(reason: "Large file but on cellular")
                #else
                    return .cloudKit(reason: "Large file + cellular Watch")
                #endif
            case .none, .unknown:
                #if os(iOS)
                    return .watchConnectivity(reason: "No WiFi, using Bluetooth")
                #else
                    return .error(reason: "No network connection available")
                #endif
            }
        }

        // Small files (<50MB)
        #if os(iOS)
            // On iPhone, use WatchConnectivity for small files if Watch is nearby
            if watchConnectivityManager.isReachable {
                return .watchConnectivity(reason: "Small file + Watch nearby")
            } else {
                return .cloudKit(reason: "Small file but Watch not nearby")
            }
        #else
            // On Watch, always use CloudKit for downloads
            return .cloudKit(reason: "Watch downloading from cloud")
        #endif
    }

    // MARK: - Transfer Execution

    /// Execute transfer using selected method
    func transfer(_ audiobook: Audiobook) async throws {
        let method = selectMethod(for: audiobook)

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
            return "CloudKit Chunks"
        case .watchConnectivity:
            return "WatchConnectivity"
        case .iCloudDirect:
            return "iCloud Direct"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            return "Automatically choose the best method"
        case .cloudKit:
            return "Fast cloud transfer (recommended for large files)"
        case .watchConnectivity:
            return "Direct device transfer (slower, no cloud storage)"
        case .iCloudDirect:
            return "Download directly from iCloud Drive"
        }
    }
}

enum SelectedMethod: CustomStringConvertible {
    case cloudKit(reason: String)
    case watchConnectivity(reason: String)
    case iCloudDirect(reason: String)
    case error(reason: String)

    var description: String {
        switch self {
        case .cloudKit(let reason):
            return "CloudKit (\(reason))"
        case .watchConnectivity(let reason):
            return "WatchConnectivity (\(reason))"
        case .iCloudDirect(let reason):
            return "iCloud Direct (\(reason))"
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
