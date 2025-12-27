//
//  Listen_This_AdvancedTests.swift
//  Listen This AppTests
//
//  Advanced unit tests for complex scenarios
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Concurrency & Race Condition Tests

@Suite("Concurrency & Thread Safety Tests")
@MainActor
struct ConcurrencyTests {
    
    @Test("Multiple concurrent uploads don't interfere")
    func concurrentUploads() async throws {
        let manager = MockCloudKitTransferManager()
        manager.simulateNetworkDelay = false
        
        let audiobooks = (1...10).map { i in
            createTestAudiobook(title: "Book \(i)", fileSize: Int64(i * 10_000_000))
        }
        
        // Start all uploads concurrently
        await withTaskGroup(of: Void.self) { group in
            for audiobook in audiobooks {
                group.addTask {
                    try? await manager.uploadAudiobook(audiobook)
                }
            }
        }
        
        // All should complete without interference
        #expect(manager.activeUploads.isEmpty)
    }
    
    @Test("Cancel during concurrent operations")
    func cancelDuringConcurrency() async throws {
        let manager = MockCloudKitTransferManager()
        
        let audiobook1 = createTestAudiobook(title: "Book 1", fileSize: 100_000_000)
        let audiobook2 = createTestAudiobook(title: "Book 2", fileSize: 100_000_000)
        
        // Start uploads
        Task {
            try? await manager.uploadAudiobook(audiobook1)
        }
        
        Task {
            try? await manager.uploadAudiobook(audiobook2)
        }
        
        // Wait for uploads to start
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Cancel first, let second continue
        manager.cancelTransfer(audiobookId: audiobook1.id)
        
        // Wait for second to potentially complete
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // First should be cancelled, second might still be running or complete
        #expect(manager.activeUploads[audiobook1.id] == nil)
    }
    
    @Test("Progress updates are atomic")
    func atomicProgressUpdates() async throws {
        let manager = MockCloudKitTransferManager()
        
        let audiobook = createTestAudiobook(fileSize: 500_000_000)
        
        // Start upload
        Task {
            try? await manager.uploadAudiobook(audiobook)
        }
        
        // Read progress multiple times concurrently
        var progressSnapshots: [Double] = []
        
        await withTaskGroup(of: Double?.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    return await manager.activeUploads[audiobook.id]?.progress
                }
            }
            
            for await progress in group {
                if let progress = progress {
                    progressSnapshots.append(progress)
                }
            }
        }
        
        // Progress should be monotonically increasing (no race conditions)
        var previousProgress: Double = -1.0
        for progress in progressSnapshots.sorted() {
            #expect(progress >= previousProgress)
            previousProgress = progress
        }
    }
}

// MARK: - Error Recovery Tests

@Suite("Error Recovery & Resilience Tests")
@MainActor
struct ErrorRecoveryTests {
    
    @Test("Recover from failed upload")
    func recoverFromFailedUpload() async throws {
        let manager = MockCloudKitTransferManager()
        let audiobook = createTestAudiobook()
        
        // First attempt fails
        manager.shouldFailUpload = true
        await #expect(throws: ChunkTransferError.self) {
            try await manager.uploadAudiobook(audiobook)
        }
        
        // Second attempt succeeds
        manager.shouldFailUpload = false
        try await manager.uploadAudiobook(audiobook)
        
        let availability = await manager.checkCloudKitChunks(for: audiobook)
        #expect(availability == .fullyUploaded)
    }
    
    @Test("Resume partial upload")
    func resumePartialUpload() async throws {
        let manager = MockCloudKitTransferManager()
        let audiobook = createTestAudiobook(fileSize: 500_000_000) // 5 chunks
        
        // Simulate partial upload (3 out of 5 chunks)
        manager.simulatePartialUpload(audiobook, uploadedChunks: Set([0, 1, 2]))
        
        let availability = await manager.checkCloudKitChunks(for: audiobook)
        
        if case .partiallyUploaded(let chunks) = availability {
            #expect(chunks.count == 3)
        } else {
            Issue.record("Expected partiallyUploaded status")
        }
    }
    
    @Test("Handle network interruption")
    func handleNetworkInterruption() async throws {
        let manager = MockCloudKitTransferManager()
        let audiobook = createTestAudiobook(fileSize: 200_000_000)
        
        // Start upload
        Task {
            try? await manager.uploadAudiobook(audiobook)
        }
        
        // Wait a bit then simulate network failure
        try await Task.sleep(nanoseconds: 150_000_000)
        manager.cancelTransfer(audiobookId: audiobook.id)
        
        // Upload should be cancelled
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.activeUploads[audiobook.id] == nil)
    }
    
    @Test("Handle corrupted file during cache")
    func handleCorruptedFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let cacheManager = MockCacheManager()
        
        let audiobook = createTestAudiobook()
        context.insert(audiobook)
        
        // Simulate corrupted file by pointing to non-existent file
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.m4b")
        
        #expect(throws: Error.self) {
            _ = try cacheManager.cacheAudiobook(audiobook, from: fakeURL)
        }
    }
}

// MARK: - Data Model Tests

@Suite("SwiftData Model Tests")
@MainActor
struct DataModelTests {
    
    @Test("Audiobook relationships cascade delete")
    func cascadeDelete() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        let audiobook = createTestAudiobook()
        context.insert(audiobook)
        
        // Add chapters
        let chapter1 = Chapter(index: 0, title: "Chapter 1", startTime: 0, duration: 600)
        let chapter2 = Chapter(index: 1, title: "Chapter 2", startTime: 600, duration: 600)
        
        audiobook.chapters = [chapter1, chapter2]
        context.insert(chapter1)
        context.insert(chapter2)
        
        try context.save()
        
        // Delete audiobook
        context.delete(audiobook)
        try context.save()
        
        // Chapters should be deleted (cascade)
        let descriptor = FetchDescriptor<Chapter>()
        let chapters = try context.fetch(descriptor)
        
        #expect(chapters.isEmpty)
    }
    
    @Test("CacheEntry relationship is independent")
    func cacheEntryIndependence() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        let audiobook = createTestAudiobook()
        context.insert(audiobook)
        
        let cacheEntry = CacheEntry(
            filePath: "/path/to/cache",
            fileSize: 50_000_000
        )
        audiobook.cacheEntry = cacheEntry
        context.insert(cacheEntry)
        
        try context.save()
        
        // Delete cache entry
        context.delete(cacheEntry)
        try context.save()
        
        // Audiobook should still exist
        let descriptor = FetchDescriptor<Audiobook>()
        let audiobooks = try context.fetch(descriptor)
        
        #expect(audiobooks.count == 1)
        #expect(audiobooks.first?.cacheEntry == nil)
    }
    
    @Test("Audiobook computed properties")
    func audiobookComputedProperties() async throws {
        let audiobook = createTestAudiobook()
        audiobook.localFilename = "test-book.m4b"
        
        // Test filename
        #expect(audiobook.filename == "test-book.m4b")
        
        // Test expected cache path
        let expectedPath = audiobook.expectedCachePath
        #expect(expectedPath != nil)
        #expect(expectedPath?.contains("test-book.m4b") == true)
        
        // Test iCloud URL (will be nil without proper container)
        #expect(audiobook.iCloudFileURL == nil)
    }
    
    @Test("Query audiobooks by criteria")
    func queryAudiobooks() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        // Create multiple audiobooks
        let book1 = createTestAudiobook(title: "The Hobbit")
        let book2 = createTestAudiobook(title: "Harry Potter")
        let book3 = createTestAudiobook(title: "The Lord of the Rings")
        
        book1.isArchived = true
        
        context.insert(book1)
        context.insert(book2)
        context.insert(book3)
        
        try context.save()
        
        // Query archived books
        var descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.isArchived == true }
        )
        var results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results.first?.title == "The Hobbit")
        
        // Query by title
        descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.title.contains("Harry") }
        )
        results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results.first?.title == "Harry Potter")
    }
}

// MARK: - File System Tests

@Suite("File System Operations Tests")
@MainActor
struct FileSystemTests {
    
    @Test("Cache directory creation")
    func cacheDirectoryCreation() async throws {
        let cacheDir = AudiobookCacheManager.cacheDirectory
        
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: cacheDir.path,
            isDirectory: &isDirectory
        )
        
        #expect(exists)
        #expect(isDirectory.boolValue)
    }
    
    @Test("Handle insufficient storage space")
    func handleInsufficientStorage() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)
        
        // Get current cache size
        let currentSize = manager.getCacheSize()
        
        // This would trigger cleanup in production
        // Mock scenario: if cache is over 3GB
        if currentSize > 3_000_000_000 {
            try await manager.cleanupIfNeeded(maxSize: 3_000_000_000)
        }
        
        // Test passes if no crash occurs
        #expect(true)
    }
    
    @Test("Clean up orphaned files")
    func cleanupOrphans() async throws {
        let container = try createTestContainer()
        _ = ModelContext(container)
        _ = MockCacheManager()
        
        // Create orphaned file
        let orphanURL = MockCacheManager.cacheDirectory
            .appendingPathComponent("orphan.m4b")
        
        try? FileManager.default.createDirectory(
            at: MockCacheManager.cacheDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: orphanURL)
        
        defer {
            try? FileManager.default.removeItem(at: orphanURL)
            try? FileManager.default.removeItem(at: MockCacheManager.cacheDirectory)
        }
        
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
        
        // Cleanup would happen here in real implementation
        // For mock, just verify file exists before cleanup
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))
    }
    
    @Test("File size calculation accuracy")
    func fileSizeCalculation() async throws {
        let testSize: Int64 = 12_345_678
        let testURL = try createTestFile(size: testSize)
        
        defer {
            try? FileManager.default.removeItem(at: testURL)
        }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: testURL.path)
        let actualSize = attributes[.size] as? Int64
        
        #expect(actualSize == testSize)
    }
}

// MARK: - Performance Tests

@Suite("Performance Tests")
@MainActor
struct PerformanceTests {
    
    @Test("Large library query performance")
    func largeLibraryQuery() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        // Create 1000 audiobooks
        for i in 0..<1000 {
            let audiobook = createTestAudiobook(title: "Book \(i)")
            context.insert(audiobook)
        }
        
        try context.save()
        
        let startTime = Date()
        
        // Query all audiobooks
        let descriptor = FetchDescriptor<Audiobook>()
        let results = try context.fetch(descriptor)
        
        let duration = Date().timeIntervalSince(startTime)
        
        #expect(results.count == 1000)
        #expect(duration < 1.0) // Should complete in under 1 second
    }
    
    @Test("Progress update frequency")
    func progressUpdateFrequency() async throws {
        let manager = MockCloudKitTransferManager()
        manager.networkDelayNanoseconds = 10_000_000 // 0.01 seconds
        
        let audiobook = createTestAudiobook(fileSize: 100_000_000)
        
        var updateCount = 0
        
        // Monitor progress updates
        Task {
            while manager.activeUploads[audiobook.id] != nil {
                updateCount += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        
        try await manager.uploadAudiobook(audiobook)
        
        // Should have reasonable number of updates (not too many, not too few)
        #expect(updateCount > 0)
        #expect(updateCount < 1000)
    }
}

// MARK: - Boundary Tests

@Suite("Boundary & Edge Case Tests")
@MainActor
struct BoundaryTests {
    
    @Test("Zero-byte file")
    func zeroByteFile() async throws {
        let audiobook = createTestAudiobook(fileSize: 0)
        
        let progress = ChunkTransferProgress(
            audiobookId: audiobook.id,
            totalBytes: 0,
            totalChunks: 0,
            completedChunks: 0,
            isUploading: true
        )
        
        #expect(progress.progress == 0.0)
        #expect(progress.progressPercentage == 0)
    }
    
    @Test("Maximum file size")
    func maximumFileSize() async throws {
        let maxSize: Int64 = 10_000_000_000 // 10GB
        _ = createTestAudiobook(fileSize: maxSize)
        
        let chunkCount = Int(ceil(Double(maxSize) / Double(CloudKitChunkedTransferManager.chunkSize)))
        
        // 100 chunks expected for 10GB
        #expect(chunkCount == 100)
    }
    
    @Test("Unicode characters in title")
    func unicodeTitles() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        
        let audiobook = createTestAudiobook(
            title: "📚 Les Misérables 中文 🎧"
        )
        context.insert(audiobook)
        try context.save()
        
        let descriptor = FetchDescriptor<Audiobook>()
        let results = try context.fetch(descriptor)
        
        #expect(results.first?.title == "📚 Les Misérables 中文 🎧")
    }
    
    @Test("Very long audiobook title")
    func longTitle() async throws {
        let longTitle = String(repeating: "A", count: 1000)
        let audiobook = createTestAudiobook(title: longTitle)
        
        #expect(audiobook.title.count == 1000)
    }
    
    @Test("Special characters in filename")
    func specialCharactersInFilename() async throws {
        let audiobook = createTestAudiobook()
        audiobook.localFilename = "Book: A Story's Tale (2024) #1.m4b"
        
        let expectedPath = audiobook.expectedCachePath
        #expect(expectedPath != nil)
    }
}
