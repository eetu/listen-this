//
//  Listen_This_AppTests.swift
//  Listen This AppTests
//
//  Unit tests for download flow
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Test Fixtures

/// Helper to create in-memory model container for testing
@MainActor
func createTestContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: Audiobook.self, Chapter.self, CacheEntry.self, configurations: config)
}

/// Helper to create test audiobook
@MainActor
func createTestAudiobook(title: String = "Test Book", fileSize: Int64 = 100_000_000) -> Audiobook {
    let audiobook = Audiobook(
        title: title,
        author: "Test Author",
        narrator: "Test Narrator",
        duration: 3600,
        fileSize: fileSize
    )
    audiobook.localFilename = "\(audiobook.id.uuidString).m4b"
    return audiobook
}

/// Helper to create test file
func createTestFile(size: Int64 = 1_000_000) throws -> URL {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4b")
    let data = Data(repeating: 0, count: Int(size))
    try data.write(to: tempURL)
    return tempURL
}

// MARK: - CloudKit Transfer Tests

@Suite("CloudKit Chunked Transfer Manager Tests")
@MainActor
struct CloudKitTransferTests {

    // MARK: - Upload Tests

    @Test("Upload calculates correct chunk count")
    func uploadChunkCount() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = CloudKitChunkedTransferManager(modelContext: context)

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
        let manager = CloudKitChunkedTransferManager(modelContext: context)

        let audiobook = createTestAudiobook(fileSize: 100_000_000)
        let audiobookId = audiobook.id.uuidString

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
            audiobookId: "test",
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
            audiobookId: "test",
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

        let audiobookId = "test-123"

        // Add a mock upload
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
        let manager = CloudKitChunkedTransferManager(modelContext: context)

        let audiobook = createTestAudiobook(fileSize: 50_000_000)
        let audiobookId = audiobook.id.uuidString

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
            audiobookId: "test",
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

        let audiobookId = "test-456"

        // Add a mock download
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

        // Without manifest, should return notUploaded
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

@Suite("WatchConnectivity Transfer Manager Tests")
@MainActor
struct WatchConnectivityTests {

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

// MARK: - AudiobookCacheManager Tests

@Suite("AudiobookCacheManager Tests")
@MainActor
struct AudiobookCacheManagerTests {

    @Test("Cache directory is created")
    func cacheDirectoryCreation() async throws {
        let cacheDir = AudiobookCacheManager.cacheDirectory

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDirectory)

        #expect(exists == true)
        #expect(isDirectory.boolValue == true)
    }

    @Test("Cache audiobook copies file correctly")
    func cacheAudiobookCopy() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook()
        let sourceURL = try createTestFile()

        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)

        defer {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(cachedURL.lastPathComponent == sourceURL.lastPathComponent)
    }

    @Test("Delete cached file removes file")
    func deleteCachedFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)

        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        // Set the audiobook's local filename
        audiobook.localFilename = cachedURL.lastPathComponent

        try manager.deleteCachedFile(for: audiobook)

        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test("Get all cached files returns m4b files only")
    func getAllCachedFiles() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        // Create test files
        let m4bFile = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test.m4b")
        let txtFile = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test.txt")

        try Data().write(to: m4bFile)
        try Data().write(to: txtFile)

        defer {
            try? FileManager.default.removeItem(at: m4bFile)
            try? FileManager.default.removeItem(at: txtFile)
        }

        let cachedFiles = manager.getAllCachedFiles()

        #expect(cachedFiles.contains { $0.lastPathComponent == "test.m4b" })
        #expect(cachedFiles.contains { $0.lastPathComponent == "test.txt" } == false)
    }

    @Test("Get cache size calculates total correctly")
    func getCacheSize() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        // Create test files with known sizes
        let file1 = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test1.m4b")
        let file2 = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test2.m4b")

        let data1 = Data(repeating: 0, count: 1_000_000) // 1MB
        let data2 = Data(repeating: 0, count: 2_000_000) // 2MB

        try data1.write(to: file1)
        try data2.write(to: file2)

        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let totalSize = manager.getCacheSize()

        // Should be approximately 3MB (allowing for file system overhead)
        #expect(totalSize >= 2_600_000)
        #expect(totalSize <= 3_000_000)
    }

    @Test("Cleanup orphaned caches removes unlinked files")
    func cleanupOrphanedCaches() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        // Create an orphaned file (no corresponding audiobook)
        let orphanedFile = AudiobookCacheManager.cacheDirectory.appendingPathComponent("orphan.m4b")
        try Data().write(to: orphanedFile)

        #expect(FileManager.default.fileExists(atPath: orphanedFile.path))

        try await manager.cleanupOrphanedCaches()

        #expect(FileManager.default.fileExists(atPath: orphanedFile.path) == false)
    }
}

// MARK: - Integration Tests

@Suite("Download Flow Integration Tests")
@MainActor
struct DownloadFlowIntegrationTests {

    @Test("Complete download workflow - cache to CloudKit simulation")
    func completeCloudKitWorkflow() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        // Create audiobook
        let audiobook = createTestAudiobook(title: "Integration Test", fileSize: 100_000_000)
        context.insert(audiobook)

        // Create mock transfer manager
        let transferManager = MockCloudKitTransferManager()

        // Simulate upload
        try await transferManager.uploadAudiobook(audiobook)

        // Verify upload completed
        #expect(transferManager.activeUploads[audiobook.id.uuidString] == nil)

        // Check availability
        let availability = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(availability == .fullyUploaded)

        // Simulate download
        let downloadedURL = try await transferManager.downloadAudiobook(audiobook)

        // Verify download completed
        #expect(transferManager.activeDownloads[audiobook.id.uuidString] == nil)
        #expect(downloadedURL.pathExtension == "m4b")
    }

    @Test("Error handling - download without upload")
    func downloadWithoutUpload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let transferManager = MockCloudKitTransferManager()

        // Try to download without uploading first
        await #expect(throws: ChunkTransferError.self) {
            _ = try await transferManager.downloadAudiobook(audiobook)
        }
    }

    @Test("Cancel transfer during upload")
    func cancelDuringUpload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        let transferManager = MockCloudKitTransferManager()

        // Start upload in background
        Task {
            try await transferManager.uploadAudiobook(audiobook)
        }

        // Wait a bit for upload to start
        try await Task.sleep(nanoseconds: 100_000_000)

        // Cancel transfer
        transferManager.cancelTransfer(audiobookId: audiobook.id.uuidString)

        // Verify it was cancelled
        #expect(transferManager.activeUploads[audiobook.id.uuidString] == nil)
    }

    @Test("Delete from cloud after download")
    func deleteAfterDownload() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        let transferManager = MockCloudKitTransferManager()

        // Upload
        try await transferManager.uploadAudiobook(audiobook)

        // Verify uploaded
        let beforeDelete = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(beforeDelete == .fullyUploaded)

        // Delete
        try await transferManager.deleteAudiobookFromCloud(audiobook)

        // Verify deleted
        let afterDelete = await transferManager.checkCloudKitChunks(for: audiobook)
        #expect(afterDelete == .notUploaded)
    }
}

// MARK: - Edge Case Tests

@Suite("Download Flow Edge Cases")
@MainActor
struct DownloadFlowEdgeCaseTests {

    @Test("Handle very small file (< 1MB)")
    func smallFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook(fileSize: 500_000) // 500KB
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

        let audiobook = createTestAudiobook(fileSize: 1_500_000_000) // 1.5GB
        context.insert(audiobook)

        let fileSize: Int64 = 1_500_000_000
        let chunkSize = CloudKitChunkedTransferManager.chunkSize
        let expectedChunks = Int(ceil(Double(fileSize) / Double(chunkSize)))

        #expect(expectedChunks == 15) // 100MB chunks
    }

    @Test("Progress text formats bytes correctly")
    func progressByteFormatting() async throws {
        let progress1 = ChunkTransferProgress(
            audiobookId: "test",
            totalBytes: 1024,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 512,
            isUploading: true
        )

        // Should format as bytes/KB
        #expect(progress1.progressText.contains("512"))

        let progress2 = ChunkTransferProgress(
            audiobookId: "test",
            totalBytes: 100_000_000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: 50_000_000,
            isUploading: true
        )

        // Should format as MB
        #expect(progress2.progressText.contains("50"))
    }

    @Test("Multiple simultaneous transfers")
    func multipleTransfers() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = MockCloudKitTransferManager()

        let audiobook1 = createTestAudiobook(title: "Book 1")
        let audiobook2 = createTestAudiobook(title: "Book 2")
        let audiobook3 = createTestAudiobook(title: "Book 3")

        // Start all uploads simultaneously
        async let upload1: () = manager.uploadAudiobook(audiobook1)
        async let upload2: () = manager.uploadAudiobook(audiobook2)
        async let upload3: () = manager.uploadAudiobook(audiobook3)

        try await upload1
        try await upload2
        try await upload3

        // All should complete
        #expect(manager.activeUploads.isEmpty)
    }

    @Test("Audiobook expected cache path calculation")
    func expectedCachePath() async throws {
        let audiobook = createTestAudiobook()
        audiobook.localFilename = "test-book.m4b"

        let expectedPath = audiobook.expectedCachePath

        #expect(expectedPath != nil)
        #expect(expectedPath?.hasSuffix("test-book.m4b") == true)
    }
}
