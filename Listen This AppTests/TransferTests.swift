//
//  TransferTests.swift
//  Listen This AppTests
//
//  Tests for CloudKit and WatchConnectivity file transfers
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - CloudKit Transfer Tests

@Suite("CloudKit Chunked Transfer Tests")
@MainActor
struct CloudKitTransferTests {

    // MARK: - Upload Tests

    @Test("Upload calculates correct chunk count")
    func uploadChunkCount() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        _ = CloudKitChunkedTransferManager(modelContext: context)

        // 100MB chunks, 250MB file = 3 chunks
        let fileSize: Int64 = 250_000_000
        let expectedChunks = 3

        let calculatedChunks = Int(ceil(Double(fileSize) / Double(CloudKitChunkedTransferManager.chunkSize)))

        #expect(calculatedChunks == expectedChunks)
    }

    @Test("Upload progress tracking initializes correctly")
    func uploadProgressTracking() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        _ = CloudKitChunkedTransferManager(modelContext: context)

        let audiobook = createTestAudiobook(fileSize: 100_000_000)
        let audiobookId = audiobook.id

        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 100_000_000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: true
        )

        #expect(progress.progress == 0.0)
        #expect(progress.progressPercentage == 0)
        #expect(progress.isUploading == true)
        #expect(progress.totalChunks == 1)
    }

    @Test("Upload progress calculates percentage correctly")
    func uploadProgressPercentage() async throws {
        var progress = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 100_000_000,
            totalChunks: 10,
            completedChunks: 5,
            bytesTransferred: 50_000_000,
            isUploading: true
        )

        #expect(progress.progress == 0.5)
        #expect(progress.progressPercentage == 50)

        progress.completedChunks = 10
        progress.bytesTransferred = 100_000_000

        #expect(progress.progress == 1.0)
        #expect(progress.progressPercentage == 100)
    }

    @Test("Upload status text formats correctly")
    func uploadStatusText() async throws {
        let progress = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 100_000_000,
            totalChunks: 10,
            completedChunks: 3,
            bytesTransferred: 30_000_000,
            isUploading: true
        )

        #expect(progress.statusText == "Uploading chunk 4 of 10")
    }

    @Test("Cancel transfer removes from active uploads")
    func cancelUpload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = CloudKitChunkedTransferManager(modelContext: context)

        let audiobookId = UUID()

        manager.activeUploads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 100_000_000,
            totalChunks: 10,
            completedChunks: 0,
            isUploading: true
        )

        #expect(manager.activeUploads[audiobookId] != nil)

        manager.cancelTransfer(audiobookId: audiobookId)

        #expect(manager.activeUploads[audiobookId] == nil)
    }

    // MARK: - Download Tests

    @Test("Download progress tracking initializes correctly")
    func downloadProgressTracking() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        _ = CloudKitChunkedTransferManager(modelContext: context)

        let audiobook = createTestAudiobook(fileSize: 50_000_000)
        let audiobookId = audiobook.id

        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 50_000_000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: false
        )

        #expect(progress.progress == 0.0)
        #expect(progress.progressPercentage == 0)
        #expect(progress.isUploading == false)
    }

    @Test("Download status text formats correctly")
    func downloadStatusText() async throws {
        let progress = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 100_000_000,
            totalChunks: 10,
            completedChunks: 7,
            bytesTransferred: 70_000_000,
            isUploading: false
        )

        #expect(progress.statusText == "Downloading chunk 8 of 10")
    }

    @Test("Cancel transfer removes from active downloads")
    func cancelDownload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = CloudKitChunkedTransferManager(modelContext: context)

        let audiobookId = UUID()

        manager.activeDownloads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 100_000_000,
            totalChunks: 10,
            completedChunks: 5,
            isUploading: false
        )

        #expect(manager.activeDownloads[audiobookId] != nil)

        manager.cancelTransfer(audiobookId: audiobookId)

        #expect(manager.activeDownloads[audiobookId] == nil)
    }

    // MARK: - Chunk Availability Tests

    @Test("Chunk availability returns correct status")
    func chunkAvailability() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = CloudKitChunkedTransferManager(modelContext: context)

        let audiobook = createTestAudiobook()

        let availability = await manager.checkCloudKitChunks(for: audiobook)
        #expect(availability == .notUploaded)
    }

    // MARK: - Error Handling Tests

    @Test("ChunkTransferError descriptions are correct")
    func errorDescriptions() async throws {
        #expect(ChunkTransferError.fileNotAvailable.errorDescription == "File is not available for transfer")
        #expect(ChunkTransferError.invalidFile.errorDescription == "File is invalid or corrupted")
        #expect(ChunkTransferError.readFailed.errorDescription == "Failed to read file data")
        #expect(ChunkTransferError.writeFailed.errorDescription == "Failed to write file data")
        #expect(ChunkTransferError.chunkNotFound.errorDescription == "Chunk data not found in CloudKit")
        #expect(ChunkTransferError.incompleteUpload.errorDescription == "Upload is incomplete, try again")
        #expect(ChunkTransferError.networkError.errorDescription == "Network error during transfer")
    }
}

// MARK: - WatchConnectivity Transfer Tests

@Suite("WatchConnectivity Transfer Tests")
@MainActor
struct WatchConnectivityTransferTests {

    @Test("WatchTransferProgress initializes correctly")
    func transferProgressInit() async throws {
        let progress = WatchTransferProgress(
            audiobookId: "test-123",
            audiobookTitle: "Test Book",
            totalBytes: 50_000_000,
            bytesTransferred: 0,
            isActive: true
        )

        #expect(progress.audiobookId == "test-123")
        #expect(progress.audiobookTitle == "Test Book")
        #expect(progress.totalBytes == 50_000_000)
        #expect(progress.bytesTransferred == 0)
        #expect(progress.isActive == true)
        #expect(progress.progress == 0.0)
    }

    @Test("WatchTransferProgress calculates progress correctly")
    func transferProgressCalculation() async throws {
        var progress = WatchTransferProgress(
            audiobookId: "test",
            audiobookTitle: "Test",
            totalBytes: 100_000_000,
            bytesTransferred: 25_000_000,
            isActive: true
        )

        #expect(progress.progress == 0.25)
        #expect(progress.progressPercentage == 25)

        progress.bytesTransferred = 100_000_000
        #expect(progress.progress == 1.0)
        #expect(progress.progressPercentage == 100)
    }

    @Test("WatchTransferProgress formats text correctly")
    func transferProgressText() async throws {
        let progress = WatchTransferProgress(
            audiobookId: "test",
            audiobookTitle: "Test",
            totalBytes: 100_000_000,
            bytesTransferred: 50_000_000,
            isActive: true
        )

        #expect(progress.progressText.contains("50"))
        #expect(progress.progressText.contains("100"))
    }

    @Test("WatchTransferProgress handles zero bytes")
    func transferProgressZeroBytes() async throws {
        let progress = WatchTransferProgress(
            audiobookId: "test",
            audiobookTitle: "Test",
            totalBytes: 0,
            bytesTransferred: 0,
            isActive: false
        )

        #expect(progress.progress == 0.0)
        #expect(progress.progressPercentage == 0)
    }

    @Test("WatchTransferError descriptions are correct")
    func watchErrorDescriptions() async throws {
        #expect(WatchTransferError.sessionUnavailable.errorDescription == "Watch Connectivity session is not available")
        #expect(WatchTransferError.watchNotAvailable.errorDescription == "Apple Watch is not paired or app is not installed")
        #expect(WatchTransferError.fileNotCached.errorDescription == "Audiobook file is not cached on iPhone")
        #expect(WatchTransferError.fileNotFound.errorDescription == "Audiobook file could not be found")
        #expect(WatchTransferError.transferFailed.errorDescription == "File transfer to Apple Watch failed")
    }
}

// MARK: - Transfer Integration Tests

@Suite("Transfer Integration Tests")
@MainActor
struct TransferIntegrationTests {

    @Test("Complete download workflow - cache to CloudKit simulation")
    func completeCloudKitWorkflow() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook(title: "Integration Test", fileSize: 100_000_000)
        context.insert(audiobook)

        let transferManager = MockCloudKitTransferManager()
        transferManager.simulateNetworkDelay = false

        try await transferManager.uploadAudiobook(audiobook)

        #expect(transferManager.activeUploads[audiobook.id] == nil)

        let availability = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(availability == .fullyUploaded)

        let downloadedURL = try await transferManager.downloadAudiobook(audiobook)

        #expect(transferManager.activeDownloads[audiobook.id] == nil)
        #expect(downloadedURL.pathExtension == "m4b")
    }

    @Test("Error handling - download without upload")
    func downloadWithoutUpload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let transferManager = MockCloudKitTransferManager()

        await #expect(throws: ChunkTransferError.self) {
            _ = try await transferManager.downloadAudiobook(audiobook)
        }
    }

    @Test("Cancel transfer during upload")
    func cancelDuringUpload() async throws {
        let container = try createTestContainer()
        _ = ModelContext(container)

        let audiobook = createTestAudiobook()
        let transferManager = MockCloudKitTransferManager()

        Task {
            try await transferManager.uploadAudiobook(audiobook)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        transferManager.cancelTransfer(audiobookId: audiobook.id)

        #expect(transferManager.activeUploads[audiobook.id] == nil)
    }

    @Test("Delete from cloud after download")
    func deleteAfterDownload() async throws {
        let container = try createTestContainer()
        _ = ModelContext(container)

        let audiobook = createTestAudiobook()
        let transferManager = MockCloudKitTransferManager()

        try await transferManager.uploadAudiobook(audiobook)

        let beforeDelete = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(beforeDelete == .fullyUploaded)

        try await transferManager.deleteAudiobookFromCloud(audiobookId: audiobook.id)

        let afterDelete = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(afterDelete == .notUploaded)
    }

    @Test("Handle very small file (< 1MB)")
    func smallFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook(fileSize: 500_000)
        context.insert(audiobook)

        let transferManager = MockCloudKitTransferManager()

        try await transferManager.uploadAudiobook(audiobook)
        let downloadedURL = try await transferManager.downloadAudiobook(audiobook)

        #expect(downloadedURL.pathExtension == "m4b")
    }

    @Test("Handle very large file (> 1GB)")
    func largeFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook(fileSize: 1_500_000_000)
        context.insert(audiobook)

        let fileSize: Int64 = 1_500_000_000
        let chunkSize = CloudKitChunkedTransferManager.chunkSize
        let expectedChunks = Int(ceil(Double(fileSize) / Double(chunkSize)))

        #expect(expectedChunks == 15)
    }

    @Test("Progress text formats bytes correctly")
    func progressByteFormatting() async throws {
        let progress1 = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 1024,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 512,
            isUploading: true
        )

        #expect(progress1.progressText.contains("512"))

        let progress2 = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 100_000_000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 50_000_000,
            isUploading: true
        )

        #expect(progress2.progressText.contains("50"))
    }

    @Test("Multiple simultaneous transfers")
    func multipleTransfers() async throws {
        let manager = MockCloudKitTransferManager()

        let audiobook1 = createTestAudiobook(title: "Book 1")
        let audiobook2 = createTestAudiobook(title: "Book 2")
        let audiobook3 = createTestAudiobook(title: "Book 3")

        async let upload1: () = manager.uploadAudiobook(audiobook1)
        async let upload2: () = manager.uploadAudiobook(audiobook2)
        async let upload3: () = manager.uploadAudiobook(audiobook3)

        try await upload1
        try await upload2
        try await upload3

        #expect(manager.activeUploads.isEmpty)
    }
}
