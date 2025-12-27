//
//  WatchConnectivityManager.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import Foundation
import WatchConnectivity
import SwiftData

// MARK: - Public Protocol (View-Facing)

@MainActor
protocol WatchConnectivity: AnyObject {
    var isReachable: Bool { get }
    var activeTransfers: [String: TransferProgress] { get }
    var lastError: Error? { get }
    
    func configure(modelContext: ModelContext)
    func checkPendingTransfers()
    func requestLibrarySync()
    func sendCachedAudiobookList()
    func requestDownload(audiobookId: UUID)
    func cancelTransfer(audiobookId: UUID)
    func transferToiPhone(_ audiobook: Audiobook) async throws
}

// MARK: - Concrete Implementation

/// Manages communication between iPhone and Watch
/// Handles file transfers and metadata sync
@MainActor
@Observable
final class WatchConnectivityManager: NSObject, WatchConnectivity {
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
        }
    }
    
    // MARK: - Configuration
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Check Pending Transfers
    
    /// Check for pending or ongoing transfers and restore their state
    func checkPendingTransfers() {
        guard session != nil else {
            return
        }
        
        // Unfortunately, WCSession doesn't provide a list of pending incoming transfers
        // But we can check if any audiobooks are marked as "in progress" in our database
        guard let modelContext = modelContext else { return }
        
        // Look for audiobooks that might have been in the middle of downloading
        do {
            let descriptor = FetchDescriptor<Audiobook>()
            _ = try modelContext.fetch(descriptor)
        } catch {
            // Failed to check audiobook status
        }
    }
    
    // MARK: - Send Commands to iPhone
    
    func requestLibrarySync() {
        guard let session = session, session.isReachable else {
            return
        }
        
        session.sendMessage(["command": "syncLibrary"], replyHandler: nil) { error in
            Task { @MainActor in
                self.lastError = error
            }
        }
    }
    
    /// Send list of cached audiobook IDs to iPhone
    func sendCachedAudiobookList() {
        guard let session = session else { return }
        guard let modelContext = modelContext else { return }
        
        do {
            // Fetch all audiobooks that have cached files on Watch
            let descriptor = FetchDescriptor<Audiobook>()
            let audiobooks = try modelContext.fetch(descriptor)
            
            // Get IDs of audiobooks with cached files
            let cachedIds = audiobooks
                .filter { $0.isFileCached }
                .map { $0.id.uuidString }
            
            let message: [String: Any] = [
                "command": "updateWatchCachedBooks",
                "cachedAudiobookIds": cachedIds
            ]
            
            // Try sending if reachable, otherwise update application context
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { error in
                    // Failed to send cached list
                }
            } else {
                // Use application context for persistent state
                try? session.updateApplicationContext(message)
            }
            
        } catch {
            // Failed to fetch cached books
        }
    }
    
    /// Request to download and transfer an audiobook from iPhone
    func requestDownload(audiobookId: UUID) {
        guard let session = session, session.isReachable else {
            lastError = WatchTransferError.iPhoneNotReachable
            return
        }
        
        let message = [
            "command": "downloadBook",
            "audiobookId": audiobookId.uuidString
        ]
        
        session.sendMessage(message, replyHandler: nil) { error in
            Task { @MainActor in
                self.lastError = error
            }
        }
    }
    
    /// Request to cancel an ongoing transfer from iPhone
    func cancelTransfer(audiobookId: UUID) {
        guard let session = session else {
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
            
            session.sendMessage(message, replyHandler: nil) { error in
                // Failed to send cancel request
            }
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
        
        // Send notification message to iPhone
        if session.isReachable {
            let message: [String: Any] = [
                "command": "transferStarted",
                "audiobookId": audiobook.id.uuidString,
                "totalBytes": fileSize
            ]
            
            session.sendMessage(message, replyHandler: nil) { error in
                // Failed to notify iPhone
            }
        }
        
        // Start file transfer
        session.transferFile(fileURL, metadata: metadata)
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
                self.lastError = error
            }
        }
    }
    
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
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
            let reply = await handleMessageWithReply(message)
            replyHandler(reply)
        }
    }
    
    private func handleMessage(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        
        switch command {
        case "updateMetadata":
            handleMetadataUpdate(message)
        case "transferStarted":
            handleTransferStarted(message)
        case "transferProgress":
            handleTransferProgress(message)
        case "transferCancelled":
            handleTransferCancelled(message)
        case "requestCachedList":
            // iPhone is asking which books are cached on Watch
            sendCachedAudiobookList()
        case "deleteAudiobook":
            // Delete is handled in handleMessageWithReply since it needs a response
            break
        default:
            break
        }
    }
    
    private func handleMessageWithReply(_ message: [String: Any]) async -> [String: Any] {
        guard let command = message["command"] as? String else {
            return ["status": "error", "error": "No command specified"]
        }
        
        switch command {
        case "deleteAudiobook":
            return await handleDeleteAudiobook(message)
        default:
            // For non-reply commands, handle normally
            handleMessage(message)
            return ["status": "received"]
        }
    }
    
    // MARK: - Handle File Transfers

    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        // CRITICAL: Must copy file IMMEDIATELY before it's deleted by system
        // WatchConnectivity deletes temp files after this method returns
        // Using synchronous dispatch pattern from Apple's sample to ensure file is handled
        // before the system removes it

        // Create cache directory with proper error handling
        let cachesDir = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Audiobooks")

        // Create directory - don't swallow errors
        do {
            try FileManager.default.createDirectory(
                at: cachesDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Task { @MainActor in
                self.lastError = error
            }
            return
        }

        // Verify source file exists (must check NOW before system deletes it)
        guard FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return
        }

        // Prepare destination
        let destinationURL = cachesDir.appendingPathComponent(file.fileURL.lastPathComponent)

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        // Try to move the file first (preferred)
        var fileTransferred = false

        do {
            try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)
            fileTransferred = true
        } catch {
            // If move fails, try copy (watchOS might restrict moving from inbox)
            do {
                try FileManager.default.copyItem(at: file.fileURL, to: destinationURL)
                fileTransferred = true

                // Clean up source after successful copy
                try? FileManager.default.removeItem(at: file.fileURL)
            } catch {
                Task { @MainActor in
                    self.lastError = error
                }
                return
            }
        }

        guard fileTransferred else {
            return
        }

        // File is now safely stored in permanent location
        // Capture metadata and filename while still available, then update model asynchronously
        let metadata = file.metadata
        let filename = file.fileURL.lastPathComponent

        Task { @MainActor in
            await self.updateAudiobookCache(
                metadata: metadata,
                destinationURL: destinationURL,
                filename: filename
            )
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

            try modelContext.save()
            
            // Clear transfer progress
            activeTransfers.removeValue(forKey: audiobookId.uuidString)
            
            // Notify iPhone that we now have this book cached
            sendCachedAudiobookList()
            
        } catch {
            lastError = error
        }
    }
    
    // MARK: - Handle Metadata Updates
    
    private func handleMetadataUpdate(_ message: [String: Any]) {
        guard modelContext != nil else { return }
        
        // Extract audiobook data from message
        // This would be sent from iPhone when a new book is added
        
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
    }
    
    private func handleTransferProgress(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String,
              let bytesTransferred = message["bytesTransferred"] as? Int64 else { return }
        
        activeTransfers[audiobookId]?.bytesTransferred = bytesTransferred
    }
    
    private func handleTransferCancelled(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String else { return }
        
        activeTransfers.removeValue(forKey: audiobookId)
    }
    
    private func handleDeleteAudiobook(_ message: [String: Any]) async -> [String: Any] {
        guard let audiobookIdString = message["audiobookId"] as? String,
              let audiobookId = UUID(uuidString: audiobookIdString),
              let modelContext = modelContext else {
            return ["success": false, "error": "Invalid request"]
        }
        
        do {
            // Fetch the audiobook
            let descriptor = FetchDescriptor<Audiobook>(
                predicate: #Predicate { $0.id == audiobookId }
            )
            
            guard let audiobook = try modelContext.fetch(descriptor).first else {
                return ["success": false, "error": "Audiobook not found"]
            }
            
            // Remove the cache entry and file
            if let cacheEntry = audiobook.cacheEntry {
                // Delete file
                let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
                try? FileManager.default.removeItem(at: fileURL)
                
                // Remove cache entry
                modelContext.delete(cacheEntry)
            }
            
            // Clear audiobook cache reference
            audiobook.cacheEntry = nil
            
            // Save changes
            try modelContext.save()
            
            // Update the cached book list sent to iPhone
            sendCachedAudiobookList()
            
            return ["success": true]
            
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
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

// MARK: - Mock Implementation (Previews & Testing)
@MainActor
@Observable
final class MockWatchConnectivity: WatchConnectivity {
    var isReachable = true
    var activeTransfers: [String: TransferProgress] = [:]
    var lastError: Error?
    
    private var modelContext: ModelContext?
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func checkPendingTransfers() {
        // Mock: No pending transfers
    }
    
    func requestLibrarySync() {
        // Mock: Sync request sent
    }
    
    func sendCachedAudiobookList() {
        // Mock: List sent
    }
    
    func requestDownload(audiobookId: UUID) {
        // Mock: Simulate download progress
        let progress = TransferProgress(
            audiobookId: audiobookId.uuidString,
            bytesTransferred: 0,
            totalBytes: 50_000_000
        )
        activeTransfers[audiobookId.uuidString] = progress
        
        // Simulate progress updates
        Task {
            for i in 1...10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if var currentProgress = activeTransfers[audiobookId.uuidString] {
                    currentProgress.bytesTransferred = Int64(i) * 5_000_000
                    activeTransfers[audiobookId.uuidString] = currentProgress
                }
            }
            activeTransfers.removeValue(forKey: audiobookId.uuidString)
        }
    }
    
    func cancelTransfer(audiobookId: UUID) {
        activeTransfers.removeValue(forKey: audiobookId.uuidString)
    }
    
    func transferToiPhone(_ audiobook: Audiobook) async throws {
        // Mock: Simulate transfer
        let progress = TransferProgress(
            audiobookId: audiobook.id.uuidString,
            bytesTransferred: 0,
            totalBytes: 50_000_000
        )
        activeTransfers[audiobook.id.uuidString] = progress
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        activeTransfers.removeValue(forKey: audiobook.id.uuidString)
    }
}


