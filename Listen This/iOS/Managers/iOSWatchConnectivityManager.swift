//
//  iOSWatchConnectivityManager.swift
//  Listen This
//
//  Manages Watch Connectivity on iPhone
//  Handles file transfers to Apple Watch
//

import Foundation
import WatchConnectivity
import SwiftData

// MARK: - Concrete Implementation

/// Manages communication between iPhone and Apple Watch
/// Handles audiobook file transfers and sync
@MainActor
@Observable
final class iOSWatchConnectivityManager: NSObject, iOSWatchConnectivity {
    static let shared = iOSWatchConnectivityManager()
    
    // MARK: - Observable State
    
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activeTransfers: [String: WatchTransferProgress] = [:]
    var watchCachedAudiobookIds: Set<String> = [] // Track which audiobooks are cached on Watch
    var lastError: Error?
    
    // MARK: - Internal Properties
    
    /// Expose session for direct messaging (internal use only)
    var session: WCSession?
    
    // MARK: - Private Properties
    
    private var modelContext: ModelContext?
    private var activeFileTransfers: [WCSessionFileTransfer] = []
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            
            Task { @MainActor in
                updateWatchStatus()
            }
        }
    }
    
    // MARK: - Configuration
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Watch Status
    
    private func updateWatchStatus() {
        guard let session = session else { return }
        
        isReachable = session.isReachable
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
    }
    
    // MARK: - File Transfer to Watch
    
    /// Transfer an audiobook file to the Apple Watch
    func transferAudiobook(_ audiobook: Audiobook) async throws {
        guard let session = session else {
            throw WatchTransferError.sessionUnavailable
        }
        
        guard session.isPaired && session.isWatchAppInstalled else {
            throw WatchTransferError.watchNotAvailable
        }
        
        // Get the cached file URL
        guard let fileURL = audiobook.validCacheFileURL else {
            throw WatchTransferError.fileNotCached
        }
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw WatchTransferError.fileNotFound
        }
        
        // Get file size
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        
        // Create metadata
        let metadata: [String: Any] = [
            "audiobookId": audiobook.id.uuidString,
            "title": audiobook.title,
            "author": audiobook.author,
            "fileSize": fileSize
        ]
        
        // Initialize transfer progress
        let progress = WatchTransferProgress(
            audiobookId: audiobook.id.uuidString,
            audiobookTitle: audiobook.title,
            totalBytes: fileSize,
            bytesTransferred: 0,
            isActive: true
        )
        
        activeTransfers[audiobook.id.uuidString] = progress
                
        // Send notification message to Watch
        if session.isReachable {
            let message: [String: Any] = [
                "command": "transferStarted",
                "audiobookId": audiobook.id.uuidString,
                "totalBytes": fileSize
            ]
            
            session.sendMessage(message, replyHandler: nil) { error in
                // Failed to notify watch
            }
        }
        
        // Start file transfer
        let transfer = session.transferFile(fileURL, metadata: metadata)
        activeFileTransfers.append(transfer)

        // Observe transfer progress
        observeTransferProgress(transfer, for: audiobook.id.uuidString)
    }
    
    /// Cancel an active transfer
    func cancelTransfer(for audiobookId: String) {
        
        // Check if transfer exists before doing anything
        guard activeTransfers[audiobookId] != nil else {
            return
        }
        
        // Find and cancel the transfer
        if let index = activeFileTransfers.firstIndex(where: {
            ($0.file.metadata?["audiobookId"] as? String) == audiobookId
        }) {
            let transfer = activeFileTransfers[index]
            transfer.cancel()
            activeFileTransfers.remove(at: index)
            
            // Notify Watch if reachable
            if let session = session, session.isReachable {
                let message: [String: Any] = [
                    "command": "transferCancelled",
                    "audiobookId": audiobookId
                ]
                
                session.sendMessage(message, replyHandler: nil) { error in
                    // Failed to notify watch of cancellation
                }
            }
        }
        
        // Remove from active transfers LAST to minimize UI updates
        // Use withMutation to batch the change if possible
        activeTransfers.removeValue(forKey: audiobookId)
    }
    
    // MARK: - Progress Observation
    
    private func observeTransferProgress(_ transfer: WCSessionFileTransfer, for audiobookId: String) {
        // Poll for progress (WCSessionFileTransfer doesn't have KVO for progress)
        Task {
            // Wait for transfer to start
            var waitCount = 0
            while !transfer.isTransferring && waitCount < 100 { // Max 10 seconds wait
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                waitCount += 1
                
                if activeTransfers[audiobookId] == nil {
                    break
                }
            }
            
            if !transfer.isTransferring && waitCount >= 100 {
                activeTransfers.removeValue(forKey: audiobookId)
                return
            }
            
            // Monitor transfer progress
            while transfer.isTransferring {
                // Update progress
                if var progress = activeTransfers[audiobookId] {
                    progress.isActive = true
                    activeTransfers[audiobookId] = progress
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                if activeTransfers[audiobookId] == nil {
                    break // Transfer was cancelled
                }
            }
            
            // Check if it completed or failed
            if activeTransfers[audiobookId] != nil {
                // Keep in activeTransfers briefly so UI shows completion
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                activeTransfers.removeValue(forKey: audiobookId)
            }
            
            // Remove from active list
            if let index = activeFileTransfers.firstIndex(where: { $0 === transfer }) {
                activeFileTransfers.remove(at: index)
            }
        }
    }
    
    // MARK: - Outstanding Transfers
    
    /// Get list of pending transfers and restore their state
    func checkOutstandingTransfers() {
        guard let session = session else { 
            return
        }
        
        let outstanding = session.outstandingFileTransfers
        
        // Track which audiobooks we've already restored to avoid duplicates
        var restoredAudiobookIds = Set<String>()
        
        for transfer in outstanding {
            if let audiobookId = transfer.file.metadata?["audiobookId"] as? String,
               let fileSize = transfer.file.metadata?["fileSize"] as? Int64,
               let title = transfer.file.metadata?["title"] as? String {
                
                // Skip if we've already restored this audiobook
                if restoredAudiobookIds.contains(audiobookId) {
                    // Cancel the duplicate transfer
                    transfer.cancel()
                    continue
                }
                
                let progress = WatchTransferProgress(
                    audiobookId: audiobookId,
                    audiobookTitle: title,
                    totalBytes: fileSize,
                    bytesTransferred: 0,
                    isActive: transfer.isTransferring
                )
                
                activeTransfers[audiobookId] = progress
                
                // Only add if not already in the list
                if !activeFileTransfers.contains(where: { $0 === transfer }) {
                    activeFileTransfers.append(transfer)
                }
                
                // Mark as restored
                restoredAudiobookIds.insert(audiobookId)
                
                // Resume observation
                observeTransferProgress(transfer, for: audiobookId)
                
                // IMPORTANT: Notify Watch about the restored transfer
                if session.isReachable {
                    let message: [String: Any] = [
                        "command": "transferStarted",
                        "audiobookId": audiobookId,
                        "totalBytes": fileSize
                    ]
                    
                    session.sendMessage(message, replyHandler: nil) { error in
                        // Failed to notify watch about restored transfer
                    }
                }
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension iOSWatchConnectivityManager: WCSessionDelegate {
    
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                self.lastError = error
            } else {
                updateWatchStatus()
                checkOutstandingTransfers()
                
                // Request cached book list from Watch after activation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.requestWatchCachedList()
                }
            }
        }
    }
    
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Session became inactive
    }
    
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Session deactivated, reactivating
        session.activate()
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            updateWatchStatus()

            // When iPhone becomes reachable to Watch, also sync our progress
            if session.isReachable {
                await self.syncPlaybackProgressToWatch()
            }
        }
    }
    
    // MARK: - Receive Messages from Watch
    
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            handleMessage(message)
        }
    }
    
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            handleMessage(message)
            replyHandler(["status": "received"])
        }
    }
    
    private func handleMessage(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }

        switch command {
        case "downloadBook":
            handleDownloadRequest(message)
        case "syncLibrary":
            handleSyncRequest()
        case "transferStarted":
            handleWatchTransferStarted(message)
        case "cancelTransfer":
            handleCancelTransferRequest(message)
        case "updateWatchCachedBooks":
            handleWatchCachedBooksUpdate(message)
        case "syncPlaybackProgress":
            handlePlaybackProgressSync(message)
        default:
            break
        }
    }
    
    private func handleDownloadRequest(_ message: [String: Any]) {
        guard let audiobookIdString = message["audiobookId"] as? String,
              let audiobookId = UUID(uuidString: audiobookIdString),
              let modelContext = modelContext else {
            return
        }
        
        Task {
            do {
                // Find the audiobook
                let descriptor = FetchDescriptor<Audiobook>(
                    predicate: #Predicate { $0.id == audiobookId }
                )
                
                guard let audiobook = try modelContext.fetch(descriptor).first else {
                    return
                }
                
                // Check if file is already cached
                if !audiobook.isFileCached {
                    // Download from iCloud first
                    let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                    _ = try await audiobook.downloadAndCache(using: cacheManager)
                }
                
                // Transfer to watch
                try await transferAudiobook(audiobook)
                
            } catch {
                lastError = error
            }
        }
    }
    
    private func handleSyncRequest() {
        // Library metadata is already synced via CloudKit
        // This is just a trigger to ensure CloudKit sync is active
    }
    
    private func handleWatchTransferStarted(_ message: [String: Any]) {
        guard message["audiobookId"] is String else { return }
    }
    
    private func handleCancelTransferRequest(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else {
            return
        }
        
        cancelTransfer(for: audiobookId)
    }
    
    private func handleWatchCachedBooksUpdate(_ message: [String: Any]) {
        guard let cachedIds = message["cachedAudiobookIds"] as? [String] else {
            return
        }
        
        watchCachedAudiobookIds = Set(cachedIds)
    }
    
    /// Request the list of cached audiobooks from Watch
    func requestWatchCachedList() {
        guard let session = session else { return }

        let message = ["command": "requestCachedList"]

        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { error in
                // Failed to request cached list
            }
        }
    }

    // MARK: - Playback Progress Sync

    /// Handle playback progress sync from Watch
    private func handlePlaybackProgressSync(_ message: [String: Any]) {
        guard let audiobookIdString = message["audiobookId"] as? String,
              let audiobookId = UUID(uuidString: audiobookIdString),
              let currentPosition = message["currentPosition"] as? Double,
              let currentChapter = message["currentChapter"] as? Int,
              let playbackRate = message["playbackRate"] as? Double,
              let lastPlayedTimestamp = message["lastPlayed"] as? TimeInterval,
              let progressPercentage = message["progressPercentage"] as? Double,
              let isCompleted = message["isCompleted"] as? Bool,
              let modelContext = modelContext else {
            return
        }

        do {
            // Find the audiobook
            let descriptor = FetchDescriptor<Audiobook>(
                predicate: #Predicate { $0.id == audiobookId }
            )

            guard let audiobook = try modelContext.fetch(descriptor).first else {
                return
            }

            let watchLastPlayed = Date(timeIntervalSince1970: lastPlayedTimestamp)

            // Get or create playback session
            let session = audiobook.playbackSession ?? {
                let s = PlaybackSession()
                audiobook.playbackSession = s
                modelContext.insert(s)
                return s
            }()

            // Only update if Watch has newer data (timestamp-based conflict resolution)
            if watchLastPlayed > session.lastPlayed {
                session.currentPosition = currentPosition
                session.currentChapter = currentChapter
                session.playbackRate = playbackRate
                session.lastPlayed = watchLastPlayed
                session.progressPercentage = progressPercentage
                session.isCompleted = isCompleted

                try modelContext.save()

                print("✅ [iOSWatchConnectivity] Adopted newer Watch progress for \(audiobook.title)")
                print("   Position: \(Int(currentPosition))s, Chapter: \(currentChapter), Last played: \(watchLastPlayed)")
            } else {
                print("ℹ️ [iOSWatchConnectivity] iPhone has newer progress for \(audiobook.title), keeping local state")
            }

        } catch {
            print("⚠️ [iOSWatchConnectivity] Failed to sync progress from Watch: \(error)")
        }
    }

    /// Sync playback progress to Watch when connection is established
    /// This ensures Watch gets latest iPhone progress immediately upon reconnection
    private func syncPlaybackProgressToWatch() async {
        guard let session = session, session.isReachable else {
            return
        }

        guard let modelContext = modelContext else {
            return
        }

        do {
            // Fetch all audiobooks with playback sessions
            let descriptor = FetchDescriptor<Audiobook>()
            let audiobooks = try modelContext.fetch(descriptor)

            // Find audiobooks with recent playback activity (within last 24 hours)
            let dayAgo = Date().addingTimeInterval(-86400)
            let recentlyPlayed = audiobooks.filter { audiobook in
                guard let session = audiobook.playbackSession else { return false }
                return session.lastPlayed > dayAgo
            }

            guard !recentlyPlayed.isEmpty else {
                return
            }

            // Send progress for each recently played audiobook
            for audiobook in recentlyPlayed {
                guard let playbackSession = audiobook.playbackSession else { continue }

                let message: [String: Any] = [
                    "command": "syncPlaybackProgress",
                    "audiobookId": audiobook.id.uuidString,
                    "currentPosition": playbackSession.currentPosition,
                    "currentChapter": playbackSession.currentChapter,
                    "playbackRate": playbackSession.playbackRate,
                    "lastPlayed": playbackSession.lastPlayed.timeIntervalSince1970,
                    "progressPercentage": playbackSession.progressPercentage,
                    "isCompleted": playbackSession.isCompleted
                ]

                // Use sendMessage for immediate delivery (requires reachability)
                session.sendMessage(message, replyHandler: nil) { error in
                    print("⚠️ [iOSWatchConnectivity] Failed to sync progress for \(audiobook.title): \(error.localizedDescription)")
                }
            }

            print("✅ [iOSWatchConnectivity] Synced progress for \(recentlyPlayed.count) audiobook(s) to Watch")

        } catch {
            print("⚠️ [iOSWatchConnectivity] Failed to sync playback progress: \(error)")
        }
    }

    // MARK: - File Transfer Delegate Methods

    /// Called when a file transfer completes or fails
    /// CRITICAL: This is essential for detecting transfer completion
    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        Task { @MainActor in
            let audiobookId = fileTransfer.file.metadata?["audiobookId"] as? String ?? "unknown"

            if let error = error {
                // Update transfer status
                if var progress = activeTransfers[audiobookId] {
                    progress.isActive = false
                    activeTransfers[audiobookId] = progress
                }

                self.lastError = error
            } else {
                // Remove from active transfers after a brief delay
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    activeTransfers.removeValue(forKey: audiobookId)
                }
            }

            // Remove from tracking
            if let index = activeFileTransfers.firstIndex(where: { $0 === fileTransfer }) {
                activeFileTransfers.remove(at: index)
            }
        }
    }

    /// Called when a file is received from Watch (bidirectional support)
    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            // iOS could receive files from Watch if user downloads on Watch first
            // For now, just log it - implement if bidirectional transfer is needed
        }
    }
}

