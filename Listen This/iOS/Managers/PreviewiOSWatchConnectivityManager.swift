//
//  PreviewIOSWatchConnectivityManager.swift
//  Listen This
//
//  Created by Eetu Sutinen on 23.12.2025.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class PreviewiOSWatchConnectivity: iOSWatchConnectivity {
    var isReachable = true
    var isPaired = true
    var isWatchAppInstalled = true
    var activeTransfers: [String: WatchTransferProgress] = [:]
    var watchCachedAudiobookIds: Set<String> = []
    var lastError: Error?
    
    private var modelContext: ModelContext?
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func transferAudiobook(_ audiobook: Audiobook) async throws {
        // Mock: Simulate transfer with progress
        let progress = WatchTransferProgress(
            audiobookId: audiobook.id.uuidString,
            audiobookTitle: audiobook.title,
            totalBytes: 50_000_000,
            bytesTransferred: 0,
            isActive: true
        )
        activeTransfers[audiobook.id.uuidString] = progress
        
        // Simulate progressive transfer
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            if var currentProgress = activeTransfers[audiobook.id.uuidString] {
                currentProgress.bytesTransferred = Int64(i) * 5_000_000
                activeTransfers[audiobook.id.uuidString] = currentProgress
            }
        }
        
        // Complete transfer
        try await Task.sleep(nanoseconds: 500_000_000)
        activeTransfers.removeValue(forKey: audiobook.id.uuidString)
        watchCachedAudiobookIds.insert(audiobook.id.uuidString)
    }
    
    func cancelTransfer(for audiobookId: String) {
        activeTransfers.removeValue(forKey: audiobookId)
    }
    
    func requestWatchCachedList() {
        // Mock: List requested
    }
    
    func checkOutstandingTransfers() {
        // Mock: No outstanding transfers
    }
}


