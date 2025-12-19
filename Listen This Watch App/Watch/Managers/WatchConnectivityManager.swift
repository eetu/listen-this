//
//  WatchConnectivityManager.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import Foundation
import WatchConnectivity
import SwiftData

/// Manages communication between iPhone and Watch
/// Handles file transfers and metadata sync
@MainActor
@Observable
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()
    
    // MARK: - Observable State
    
    var isReachable = false
    var activeTransfers: [String: TransferProgress] = [:]
    var lastError: Error?
    
    // MARK: - Private Properties
    
    private var session: WCSession?
    private var modelContext: ModelContext?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            print("📱 [WatchConnectivity] Session activated")
        }
    }
    
    // MARK: - Configuration
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        print("⌚ [WatchConnectivity] Configured with model context")
    }
    
    // MARK: - Check Pending Transfers
    
    /// Check for pending or ongoing transfers and restore their state
    func checkPendingTransfers() {
        guard let session = session else {
            print("⌚ [WatchConnectivity] No session available for checking transfers")
            return
        }
        
        // Check if there are any file transfers that haven't been received yet
        let hasTransfers = session.hasContentPending
        
        print("⌚ [WatchConnectivity] Checking pending transfers...")
        print("⌚ [WatchConnectivity] Has content pending: \(hasTransfers)")
        
        // Unfortunately, WCSession doesn't provide a list of pending incoming transfers
        // But we can check if any audiobooks are marked as "in progress" in our database
        guard let modelContext = modelContext else { return }
        
        // Look for audiobooks that might have been in the middle of downloading
        do {
            let descriptor = FetchDescriptor<Audiobook>()
            let audiobooks = try modelContext.fetch(descriptor)
            
            let cachedCount = audiobooks.filter { $0.isFileCached }.count
            let totalCount = audiobooks.count
            
            print("⌚ [WatchConnectivity] Library status:")
            print("   Total audiobooks: \(totalCount)")
            print("   Cached locally: \(cachedCount)")
            print("   Pending: \(totalCount - cachedCount)")
            
        } catch {
            print("❌ [WatchConnectivity] Failed to check audiobook status: \(error)")
        }
    }
    
    // MARK: - Send Commands to iPhone
    
    func requestLibrarySync() {
        guard let session = session, session.isReachable else {
            print("⚠️ [WatchConnectivity] iPhone not reachable")
            return
        }
        
        session.sendMessage(["command": "syncLibrary"], replyHandler: nil) { error in
            Task { @MainActor in
                print("❌ [WatchConnectivity] Failed to request sync: \(error)")
                self.lastError = error
            }
        }
    }
    
    /// Request to download and transfer an audiobook from iPhone
    func requestDownload(audiobookId: UUID) {
        guard let session = session, session.isReachable else {
            print("⚠️ [WatchConnectivity] iPhone not reachable")
            lastError = WatchTransferError.iPhoneNotReachable
            return
        }
        
        let message = [
            "command": "downloadBook",
            "audiobookId": audiobookId.uuidString
        ]
        
        print("📥 [WatchConnectivity] Requesting download: \(audiobookId)")
        
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                print("✅ [WatchConnectivity] Download request acknowledged")
            }
        }) { error in
            Task { @MainActor in
                print("❌ [WatchConnectivity] Failed to request download: \(error)")
                self.lastError = error
            }
        }
    }
    
    /// Request to cancel an ongoing transfer from iPhone
    func cancelTransfer(audiobookId: UUID) {
        guard let session = session else {
            print("⚠️ [WatchConnectivity] No session available")
            return
        }
        
        // Remove from active transfers immediately for UI responsiveness
        activeTransfers.removeValue(forKey: audiobookId.uuidString)
        
        // If reachable, send cancel command to iPhone
        if session.isReachable {
            let message = [
                "command": "cancelTransfer",
                "audiobookId": audiobookId.uuidString
            ]
            
            print("🛑 [WatchConnectivity] Requesting transfer cancellation: \(audiobookId)")
            
            session.sendMessage(message, replyHandler: { reply in
                Task { @MainActor in
                    print("✅ [WatchConnectivity] Cancel request acknowledged")
                }
            }) { error in
                Task { @MainActor in
                    print("⚠️ [WatchConnectivity] Failed to send cancel request: \(error)")
                    // Still removed locally, so this is not critical
                }
            }
        } else {
            print("⚠️ [WatchConnectivity] iPhone not reachable, cancelling locally only")
        }
    }
    
    // MARK: - Transfer to iPhone (if needed)
    
    /// Transfer an audiobook file to iPhone (if user downloaded on Watch first)
    func transferToiPhone(_ audiobook: Audiobook) async throws {
        guard let session = session else {
            throw WatchTransferError.sessionUnavailable
        }
        
        // Get the cached file URL
        guard let cachePath = audiobook.expectedCachePath else {
            throw WatchTransferError.fileNotCached
        }
        
        let fileURL = URL(fileURLWithPath: cachePath)
        
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
        let progress = TransferProgress(
            audiobookId: audiobook.id.uuidString,
            bytesTransferred: 0,
            totalBytes: fileSize
        )
        
        activeTransfers[audiobook.id.uuidString] = progress
        
        print("📤 [WatchConnectivity] Starting transfer to iPhone: \(audiobook.title)")
        print("   File: \(fileURL.lastPathComponent)")
        print("   Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        
        // Send notification message to iPhone
        if session.isReachable {
            let message: [String: Any] = [
                "command": "transferStarted",
                "audiobookId": audiobook.id.uuidString,
                "totalBytes": fileSize
            ]
            
            session.sendMessage(message, replyHandler: nil) { error in
                print("⚠️ [WatchConnectivity] Failed to notify iPhone: \(error)")
            }
        }
        
        // Start file transfer
        _ = session.transferFile(fileURL, metadata: metadata)
        
        print("✅ [WatchConnectivity] Transfer to iPhone initiated")
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                print("❌ [WatchConnectivity] Activation error: \(error)")
                self.lastError = error
            } else {
                print("✅ [WatchConnectivity] Session activated: \(activationState.rawValue)")
            }
        }
    }
    
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        print("⚠️ [WatchConnectivity] Session became inactive")
    }
    
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        print("⚠️ [WatchConnectivity] Session deactivated, reactivating...")
        session.activate()
    }
    #endif
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            print("📱 [WatchConnectivity] Reachability: \(session.isReachable)")
        }
    }
    
    // MARK: - Receive Messages
    
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
        
        print("📨 [WatchConnectivity] Received command: \(command)")
        
        switch command {
        case "updateMetadata":
            handleMetadataUpdate(message)
        case "transferStarted":
            handleTransferStarted(message)
        case "transferProgress":
            handleTransferProgress(message)
        case "transferCancelled":
            handleTransferCancelled(message)
        default:
            print("⚠️ [WatchConnectivity] Unknown command: \(command)")
        }
    }
    
    // MARK: - Handle File Transfers

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as? Int64) ?? 0

        print("📥 [WatchConnectivity] ===== FILE RECEIVED =====")
        print("📥 [WatchConnectivity] File: \(file.fileURL.lastPathComponent)")
        print("📥 [WatchConnectivity] Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
        print("📥 [WatchConnectivity] Metadata: \(file.metadata ?? [:])")

        // CRITICAL: Must copy file IMMEDIATELY before it's deleted by system
        // WatchConnectivity deletes temp files after this method returns
        // Using synchronous dispatch pattern from Apple's sample to ensure file is handled
        // before the system removes it

        // Create cache directory with proper error handling
        let cachesDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")

        print("📂 [WatchConnectivity] Cache directory: \(cachesDir.path)")

        // Create directory - don't swallow errors
        do {
            try FileManager.default.createDirectory(
                at: cachesDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            print("✅ [WatchConnectivity] Cache directory created/verified")
        } catch {
            print("❌ [WatchConnectivity] Failed to create cache directory: \(error)")
            DispatchQueue.main.sync {
                Task { @MainActor in
                    self.lastError = error
                }
            }
            return
        }

        // Verify source file exists (must check NOW before system deletes it)
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            print("❌ [WatchConnectivity] Source file doesn't exist: \(file.fileURL.path)")
            return
        }

        print("✅ [WatchConnectivity] Source file exists: \(file.fileURL.path)")

        // Prepare destination
        let destinationURL = cachesDir.appendingPathComponent(file.fileURL.lastPathComponent)
        print("📋 [WatchConnectivity] Destination: \(destinationURL.path)")

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            do {
                try FileManager.default.removeItem(at: destinationURL)
                print("🗑️ [WatchConnectivity] Removed existing file")
            } catch {
                print("⚠️ [WatchConnectivity] Failed to remove existing: \(error)")
            }
        }

        // Try to move the file first (preferred)
        var fileTransferred = false

        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)
            print("✅ [WatchConnectivity] File moved successfully")
            fileTransferred = true
        } catch {
            print("⚠️ [WatchConnectivity] Move failed, trying copy: \(error)")

            // If move fails, try copy (watchOS might restrict moving from inbox)
            do {
                try FileManager.default.copyItem(at: file.fileURL, to: destinationURL)
                print("✅ [WatchConnectivity] File copied successfully")
                fileTransferred = true

                // Clean up source after successful copy
                try? FileManager.default.removeItem(at: file.fileURL)
            } catch {
                print("❌ [WatchConnectivity] Both move and copy failed: \(error)")
                print("   Source: \(file.fileURL.path)")
                print("   Destination: \(destinationURL.path)")
                DispatchQueue.main.sync {
                    Task { @MainActor in
                        self.lastError = error
                    }
                }
                return
            }
        }

        guard fileTransferred else {
            print("❌ [WatchConnectivity] File transfer failed")
            return
        }

        print("✅ [WatchConnectivity] File saved to: \(destinationURL.path)")

        // CRITICAL: Use synchronous dispatch to ensure model update begins before method returns
        // This follows Apple's pattern from TransferringDataWithWatchConnectivity sample
        // The system removes WCSessionFile.fileURL once this method returns, so we must
        // capture all necessary data and dispatch to main queue synchronously
        let metadata = file.metadata
        let filename = file.fileURL.lastPathComponent

        DispatchQueue.main.sync {
            Task { @MainActor in
                await self.updateAudiobookCache(
                    metadata: metadata,
                    destinationURL: destinationURL,
                    filename: filename
                )
            }
        }
    }
    
    private func updateAudiobookCache(
        metadata: [String: Any]?,
        destinationURL: URL,
        filename: String
    ) async {
        guard let metadata = metadata,
              let audiobookIdString = metadata["audiobookId"] as? String,
              let audiobookId = UUID(uuidString: audiobookIdString),
              let modelContext = modelContext else {
            print("❌ [WatchConnectivity] Invalid file metadata")
            return
        }
        
        do {
            // Find the audiobook
            let descriptor = FetchDescriptor<Audiobook>(
                predicate: #Predicate { $0.id == audiobookId }
            )
            
            guard let audiobook = try modelContext.fetch(descriptor).first else {
                print("❌ [WatchConnectivity] Audiobook not found: \(audiobookId)")
                return
            }
            
            print("✅ [WatchConnectivity] File saved to: \(destinationURL.path)")
            
            // Update or create cache entry
            if audiobook.cacheEntry == nil {
                let cacheEntry = CacheEntry()
                cacheEntry.audiobook = audiobook
                audiobook.cacheEntry = cacheEntry
                modelContext.insert(cacheEntry)
            }
            
            audiobook.cacheEntry?.filePath = destinationURL.path
            audiobook.cacheEntry?.fileSize = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
            audiobook.cacheEntry?.lastAccessedDate = Date()
            audiobook.downloadDate = Date()
            
            // Store filename for cache path calculation
            audiobook.localFilename = filename
            
            try modelContext.save()
            
            // Clear transfer progress
            activeTransfers.removeValue(forKey: audiobookId.uuidString)
            
            print("✅ [WatchConnectivity] Audiobook cached successfully")
            
        } catch {
            print("❌ [WatchConnectivity] Failed to save file: \(error)")
            lastError = error
        }
    }
    
    // MARK: - Handle Metadata Updates
    
    private func handleMetadataUpdate(_ message: [String: Any]) {
        guard let modelContext = modelContext else { return }
        
        // Extract audiobook data from message
        // This would be sent from iPhone when a new book is added
        print("📝 [WatchConnectivity] Processing metadata update")
        
        // Implementation depends on your metadata structure
        // For now, just log that we received it
    }
    
    private func handleTransferStarted(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else { return }
        
        let totalBytes = message["totalBytes"] as? Int64 ?? 0
        
        let progress = TransferProgress(
            audiobookId: audiobookId,
            bytesTransferred: 0,
            totalBytes: totalBytes
        )
        
        activeTransfers[audiobookId] = progress
        
        print("📤 [WatchConnectivity] Transfer started")
        print("   Audiobook ID: \(audiobookId)")
        print("   Total size: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
        print("   Active transfers count: \(activeTransfers.count)")
    }
    
    private func handleTransferProgress(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String,
              let bytesTransferred = message["bytesTransferred"] as? Int64 else { return }
        
        activeTransfers[audiobookId]?.bytesTransferred = bytesTransferred
        
        if let progress = activeTransfers[audiobookId] {
            let percent = Double(progress.bytesTransferred) / Double(progress.totalBytes) * 100
            print("📊 [WatchConnectivity] Transfer progress: \(Int(percent))% (\(progress.progressText))")
        }
    }
    
    private func handleTransferCancelled(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else { return }
        
        activeTransfers.removeValue(forKey: audiobookId)
        
        print("🛑 [WatchConnectivity] Transfer cancelled by iPhone: \(audiobookId)")
    }
}

// MARK: - Transfer Progress Model

struct TransferProgress {
    let audiobookId: String
    var bytesTransferred: Int64
    let totalBytes: Int64
    var startDate: Date = Date()
    
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
    
    var estimatedTimeRemaining: TimeInterval? {
        guard bytesTransferred > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startDate)
        let rate = Double(bytesTransferred) / elapsed
        let remaining = Double(totalBytes - bytesTransferred) / rate
        return remaining
    }
}
// MARK: - Transfer Errors

enum WatchTransferError: LocalizedError {
    case sessionUnavailable
    case iPhoneNotReachable
    case fileNotCached
    case fileNotFound
    case transferFailed
    
    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "Watch Connectivity session is not available"
        case .iPhoneNotReachable:
            return "iPhone is not reachable"
        case .fileNotCached:
            return "Audiobook file is not cached"
        case .fileNotFound:
            return "Audiobook file could not be found"
        case .transferFailed:
            return "File transfer failed"
        }
    }
}

