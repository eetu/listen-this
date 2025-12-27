//
//  CloudKitTransferManager.swift
//  Listen This
//
//  Protocol for CloudKit transfer operations
//

import Foundation

/// Protocol for managing CloudKit audiobook transfers
@MainActor
protocol CloudKitTransferManager: AnyObject {
    var activeUploads: [UUID: ChunkTransferProgress] { get }
    var activeDownloads: [UUID: ChunkTransferProgress] { get }

    func uploadAudiobook(_ audiobook: Audiobook) async throws
    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL
    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws
    func deleteAudiobookFromCloud(audiobookId: UUID) async throws
    func checkCloudKitChunks(for audiobook: Audiobook) async -> ChunkAvailability
    func cancelTransfer(audiobookId: UUID)
}
