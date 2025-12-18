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
    
    func requestDownload(audiobookId: UUID) {
        guard let session = session, session.isReachable else {
            print("⚠️ [WatchConnectivity] iPhone not reachable")
            return
        }
        
        let message = [
            "command": "downloadBook",
            "audiobookId": audiobookId.uuidString
        ]
        
        session.sendMessage(message, replyHandler: nil) { error in
            Task { @MainActor in
                print("❌ [WatchConnectivity] Failed to request download: \(error)")
                self.lastError = error
            }
        }
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
        default:
            print("⚠️ [WatchConnectivity] Unknown command: \(command)")
        }
    }
    
    // MARK: - Handle File Transfers
    
    nonisolated func session(
        _ session: WCSession,
        didReceive file: WCSessionFile
    ) {
        Task { @MainActor in
            await handleReceivedFile(file)
        }
    }
    
    private func handleReceivedFile(_ file: WCSessionFile) async {
        print("📥 [WatchConnectivity] Received file: \(file.fileURL.lastPathComponent)")
        
        guard let metadata = file.metadata,
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
            
            // Create cache directory if needed
            let cachesDir = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Audiobooks")
            
            try? FileManager.default.createDirectory(
                at: cachesDir,
                withIntermediateDirectories: true
            )
            
            // Move file to cache
            let destinationURL = cachesDir.appendingPathComponent(file.fileURL.lastPathComponent)
            
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destinationURL)
            
            try FileManager.default.moveItem(at: file.fileURL, to: destinationURL)
            
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
            audiobook.localFilename = file.fileURL.lastPathComponent
            
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
        
        let progress = TransferProgress(
            audiobookId: audiobookId,
            bytesTransferred: 0,
            totalBytes: message["totalBytes"] as? Int64 ?? 0
        )
        
        activeTransfers[audiobookId] = progress
        print("📤 [WatchConnectivity] Transfer started for: \(audiobookId)")
    }
    
    private func handleTransferProgress(_ message: [String: Any]) {
        guard let audiobookId = message["audiobookId"] as? String,
              let bytesTransferred = message["bytesTransferred"] as? Int64 else { return }
        
        activeTransfers[audiobookId]?.bytesTransferred = bytesTransferred
        
        if let progress = activeTransfers[audiobookId] {
            let percent = Double(progress.bytesTransferred) / Double(progress.totalBytes) * 100
            print("📊 [WatchConnectivity] Transfer progress: \(Int(percent))%")
        }
    }
}

// MARK: - Transfer Progress Model

struct TransferProgress {
    let audiobookId: String
    var bytesTransferred: Int64
    let totalBytes: Int64
    
    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}
