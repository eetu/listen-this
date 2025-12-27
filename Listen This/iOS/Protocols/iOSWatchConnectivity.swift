//
//  iOSWatchConnectivity.swift
//  Listen This
//
//  Protocol for iOS-Watch connectivity operations
//

import Foundation
import SwiftData
import WatchConnectivity

/// Protocol for managing iPhone-Watch connectivity
@MainActor
protocol iOSWatchConnectivity: AnyObject {
    var isReachable: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activeTransfers: [String: WatchTransferProgress] { get }
    var watchCachedAudiobookIds: Set<String> { get set }
    var lastError: Error? { get }
    var session: WCSession? { get }

    func configure(modelContext: ModelContext)
    func transferAudiobook(_ audiobook: Audiobook) async throws
    func cancelTransfer(for audiobookId: String)
    func requestWatchCachedList()
    func checkOutstandingTransfers()
}
