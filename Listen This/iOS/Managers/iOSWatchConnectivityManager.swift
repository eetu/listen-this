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

#if os(iOS)

/// Manages communication between iPhone and Apple Watch
/// Handles audiobook file transfers and sync
@MainActor
@Observable
final class iOSWatchConnectivityManager: NSObject {
    static let shared = iOSWatchConnectivityManager()
    
    // MARK: - Observable State
    
    var isReachable = false
    var isPaired = false
    var isWatchAppInstalled = false
    var activeTransfers: [String: WatchTransferProgress] = [:]
    var lastError: Error?
    
    // MARK: - Private Properties
    
    private var session: WCSession?
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
            
            print("📱 [iOS-WatchConnectivity] Session activated")
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
        
        print("📱 [iOS-WatchConnectivity] Status:")
        print("   Paired: \(isPaired)")
        print("   App installed: \(isWatchAppInstalled)")
        print("   Reachable: \(isReachable)")
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
        
        print("📤 [iOS-WatchConnectivity] Starting transfer: \(audiobook.title)")
        print("   File: \(fileURL.lastPathComponent)")
        print("   Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        
        // Send notification message to Watch
        if session.isReachable {
            let message: [String: Any] = [
                "command": "transferStarted",
                "audiobookId": audiobook.id.uuidString,
                "totalBytes": fileSize
            ]
            
            session.sendMessage(message, replyHandler: nil) { error in
                print("⚠️ [iOS-WatchConnectivity] Failed to notify watch: \(error)")
            }
        }
        
        // Start file transfer
        let transfer = session.transferFile(fileURL, metadata: metadata)
        activeFileTransfers.append(transfer)

        print("✅ [iOS-WatchConnectivity] Transfer initiated")
        print("   Transfer object created: \(transfer)")
        print("   File URL: \(fileURL.path)")
        print("   File exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        print("   Transfer.isTransferring: \(transfer.isTransferring)")
        print("   Session.activationState: \(session.activationState.rawValue)")
        print("   Session.isPaired: \(session.isPaired)")
        print("   Session.isWatchAppInstalled: \(session.isWatchAppInstalled)")
        print("   Session.isReachable: \(session.isReachable)")
        print("   Outstanding transfers count: \(session.outstandingFileTransfers.count)")

        // Observe transfer progress
        observeTransferProgress(transfer, for: audiobook.id.uuidString)
    }
    
    /// Cancel an active transfer
    func cancelTransfer(for audiobookId: String) {
        // Find and cancel the transfer
        if let index = activeFileTransfers.firstIndex(where: {
            ($0.file.metadata?["audiobookId"] as? String) == audiobookId
        }) {
            let transfer = activeFileTransfers[index]
            transfer.cancel()
            activeFileTransfers.remove(at: index)
            
            // Remove from active transfers
            activeTransfers.removeValue(forKey: audiobookId)
            
            print("🛑 [iOS-WatchConnectivity] Transfer cancelled: \(audiobookId)")
            
            // Notify Watch if reachable
            if let session = session, session.isReachable {
                let message: [String: Any] = [
                    "command": "transferCancelled",
                    "audiobookId": audiobookId
                ]
                
                session.sendMessage(message, replyHandler: nil) { error in
                    print("⚠️ [iOS-WatchConnectivity] Failed to notify watch of cancellation: \(error)")
                }
            }
        }
    }
    
    // MARK: - Progress Observation
    
    private func observeTransferProgress(_ transfer: WCSessionFileTransfer, for audiobookId: String) {
        // Poll for progress (WCSessionFileTransfer doesn't have KVO for progress)
        Task {
            print("👀 [iOS-WatchConnectivity] Starting to observe transfer: \(audiobookId)")
            
            // Wait for transfer to start
            var waitCount = 0
            while !transfer.isTransferring && waitCount < 100 { // Max 10 seconds wait
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                waitCount += 1
                
                if activeTransfers[audiobookId] == nil {
                    print("⚠️ [iOS-WatchConnectivity] Transfer cancelled before starting: \(audiobookId)")
                    break // Transfer was cancelled or removed
                }
            }
            
            if !transfer.isTransferring && waitCount >= 100 {
                print("⚠️ [iOS-WatchConnectivity] Transfer never started: \(audiobookId)")
                activeTransfers.removeValue(forKey: audiobookId)
                return
            }
            
            print("🚀 [iOS-WatchConnectivity] Transfer is now active: \(audiobookId)")
            
            // Monitor transfer progress
            var lastLogTime = Date()
            while transfer.isTransferring {
                // Update progress
                if var progress = activeTransfers[audiobookId] {
                    progress.isActive = true
                    activeTransfers[audiobookId] = progress
                    
                    // Log progress every 5 seconds
                    if Date().timeIntervalSince(lastLogTime) >= 5.0 {
                        print("📊 [iOS-WatchConnectivity] Transfer still active: \(audiobookId)")
                        lastLogTime = Date()
                    }
                }
                
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                if activeTransfers[audiobookId] == nil {
                    print("🛑 [iOS-WatchConnectivity] Transfer cancelled: \(audiobookId)")
                    break // Transfer was cancelled
                }
            }
            
            // Check if it completed or failed
            if activeTransfers[audiobookId] != nil {
                print("✅ [iOS-WatchConnectivity] Transfer completed: \(audiobookId)")
                
                // Keep in activeTransfers briefly so UI shows completion
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                
                await MainActor.run {
                    activeTransfers.removeValue(forKey: audiobookId)
                }
            }
            
            // Remove from active list
            if let index = activeFileTransfers.firstIndex(where: { $0 === transfer }) {
                await MainActor.run {
                    activeFileTransfers.remove(at: index)
                }
            }
            
            print("🏁 [iOS-WatchConnectivity] Finished observing transfer: \(audiobookId)")
        }
    }
    
    // MARK: - Outstanding Transfers
    
    /// Get list of pending transfers and restore their state
    func checkOutstandingTransfers() {
        guard let session = session else { 
            print("📊 [iOS-WatchConnectivity] No session available")
            return 
        }
        
        let outstanding = session.outstandingFileTransfers
        print("📊 [iOS-WatchConnectivity] Checking outstanding transfers...")
        print("📊 [iOS-WatchConnectivity] Found \(outstanding.count) outstanding transfers")
        
        // Track which audiobooks we've already restored to avoid duplicates
        var restoredAudiobookIds = Set<String>()
        
        for transfer in outstanding {
            if let audiobookId = transfer.file.metadata?["audiobookId"] as? String,
               let fileSize = transfer.file.metadata?["fileSize"] as? Int64,
               let title = transfer.file.metadata?["title"] as? String {
                
                // Skip if we've already restored this audiobook
                if restoredAudiobookIds.contains(audiobookId) {
                    print("⚠️ [iOS-WatchConnectivity] Skipping duplicate transfer: \(title)")
                    print("   - Audiobook ID: \(audiobookId)")
                    print("   - This is a duplicate, cancelling...")
                    
                    // Cancel the duplicate transfer
                    transfer.cancel()
                    continue
                }
                
                print("📊 [iOS-WatchConnectivity] Restoring transfer: \(title)")
                print("   - Audiobook ID: \(audiobookId)")
                print("   - Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
                print("   - Is transferring: \(transfer.isTransferring)")
                
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
                        print("⚠️ [iOS-WatchConnectivity] Failed to notify watch about restored transfer: \(error)")
                    }
                    
                    print("📡 [iOS-WatchConnectivity] Notified watch about restored transfer: \(title)")
                }
                
                print("✅ [iOS-WatchConnectivity] Transfer restored and monitoring resumed")
            }
        }
        
        if outstanding.isEmpty {
            print("📊 [iOS-WatchConnectivity] No outstanding transfers found")
        } else {
            print("📊 [iOS-WatchConnectivity] Restored \(restoredAudiobookIds.count) unique transfers (cancelled \(outstanding.count - restoredAudiobookIds.count) duplicates)")
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
                print("❌ [iOS-WatchConnectivity] Activation error: \(error)")
                self.lastError = error
            } else {
                print("✅ [iOS-WatchConnectivity] Session activated: \(activationState.rawValue)")
                updateWatchStatus()
                checkOutstandingTransfers()
            }
        }
    }
    
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("⚠️ [iOS-WatchConnectivity] Session became inactive")
    }
    
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        print("⚠️ [iOS-WatchConnectivity] Session deactivated, reactivating...")
        session.activate()
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            print("📱 [iOS-WatchConnectivity] Reachability changed: \(session.isReachable)")
            updateWatchStatus()
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
        
        print("📨 [iOS-WatchConnectivity] Received command: \(command)")
        
        switch command {
        case "downloadBook":
            handleDownloadRequest(message)
        case "syncLibrary":
            handleSyncRequest()
        case "transferStarted":
            handleWatchTransferStarted(message)
        case "cancelTransfer":
            handleCancelTransferRequest(message)
        default:
            print("⚠️ [iOS-WatchConnectivity] Unknown command: \(command)")
        }
    }
    
    private func handleDownloadRequest(_ message: [String: Any]) {
        guard let audiobookIdString = message["audiobookId"] as? String,
              let audiobookId = UUID(uuidString: audiobookIdString),
              let modelContext = modelContext else {
            print("❌ [iOS-WatchConnectivity] Invalid download request")
            return
        }
        
        Task {
            do {
                // Find the audiobook
                let descriptor = FetchDescriptor<Audiobook>(
                    predicate: #Predicate { $0.id == audiobookId }
                )
                
                guard let audiobook = try modelContext.fetch(descriptor).first else {
                    print("❌ [iOS-WatchConnectivity] Audiobook not found")
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
                print("❌ [iOS-WatchConnectivity] Download request failed: \(error)")
                lastError = error
            }
        }
    }
    
    private func handleSyncRequest() {
        print("📱 [iOS-WatchConnectivity] Sync request received")
        // Library metadata is already synced via CloudKit
        // This is just a trigger to ensure CloudKit sync is active
    }
    
    private func handleWatchTransferStarted(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else { return }
        print("📤 [iOS-WatchConnectivity] Watch confirmed transfer started: \(audiobookId)")
    }
    
    private func handleCancelTransferRequest(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else {
            print("⚠️ [iOS-WatchConnectivity] Invalid cancel request - missing audiobookId")
            return
        }
        
        print("🛑 [iOS-WatchConnectivity] Watch requested to cancel transfer: \(audiobookId)")
        cancelTransfer(for: audiobookId)
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
                print("❌ [iOS-WatchConnectivity] Transfer FAILED: \(audiobookId)")
                print("   Error: \(error.localizedDescription)")

                // Update transfer status
                if var progress = activeTransfers[audiobookId] {
                    progress.isActive = false
                    activeTransfers[audiobookId] = progress
                }

                self.lastError = error
            } else {
                print("✅ [iOS-WatchConnectivity] Transfer COMPLETED: \(audiobookId)")
                print("   File: \(fileTransfer.file.fileURL.lastPathComponent)")

                // Remove from active transfers after a brief delay
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    await MainActor.run {
                        activeTransfers.removeValue(forKey: audiobookId)
                    }
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
            print("📥 [iOS-WatchConnectivity] Received file from Watch:")
            print("   File: \(file.fileURL.lastPathComponent)")
            print("   Metadata: \(file.metadata ?? [:])")

            // iOS could receive files from Watch if user downloads on Watch first
            // For now, just log it - implement if bidirectional transfer is needed
        }
    }
}

// MARK: - Watch Transfer Progress

struct WatchTransferProgress {
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

#endif
