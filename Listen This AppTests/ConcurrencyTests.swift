//
//  ConcurrencyTests.swift
//  Listen This AppTests
//
//  Tests for concurrency, thread safety, error recovery, and performance
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Concurrency & Thread Safety Tests

@Suite("Concurrency & Thread Safety Tests")
@MainActor
struct ThreadSafetyTests {

    @Test("Multiple concurrent uploads don't interfere")
    func concurrentUploads() async throws {
        let manager = MockCloudKitTransferManager()
        manager.simulateNetworkDelay = false

        let audiobooks = (1...10).map { i in
            createTestAudiobook(title: "Book \(i)", fileSize: Int64(i * 10_000_000))
        }

        await withTaskGroup(of: Void.self) { group in
            for audiobook in audiobooks {
                group.addTask {
                    try? await manager.uploadAudiobook(audiobook)
                }
            }
        }

        #expect(manager.activeUploads.isEmpty)
    }

    @Test("Cancel during concurrent operations")
    func cancelDuringConcurrency() async throws {
        let manager = MockCloudKitTransferManager()

        let audiobook1 = createTestAudiobook(title: "Book 1", fileSize: 100_000_000)
        let audiobook2 = createTestAudiobook(title: "Book 2", fileSize: 100_000_000)

        Task {
            try? await manager.uploadAudiobook(audiobook1)
        }

        Task {
            try? await manager.uploadAudiobook(audiobook2)
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        manager.cancelTransfer(audiobookId: audiobook1.id)

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(manager.activeUploads[audiobook1.id] == nil)
    }

    @Test("Progress updates are atomic")
    func atomicProgressUpdates() async throws {
        let manager = MockCloudKitTransferManager()

        let audiobook = createTestAudiobook(fileSize: 500_000_000)

        Task {
            try? await manager.uploadAudiobook(audiobook)
        }

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

        manager.shouldFailUpload = true
        await #expect(throws: ChunkTransferError.self) {
            try await manager.uploadAudiobook(audiobook)
        }

        manager.shouldFailUpload = false
        try await manager.uploadAudiobook(audiobook)

        let availability = await manager.checkCloudKitChunks(for: audiobook)
        #expect(availability == .fullyUploaded)
    }

    @Test("Resume partial upload")
    func resumePartialUpload() async throws {
        let manager = MockCloudKitTransferManager()
        let audiobook = createTestAudiobook(fileSize: 500_000_000)

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
        manager.simulateNetworkDelay = true
        manager.networkDelayNanoseconds = 100_000_000 // Slow enough to cancel

        let audiobook = createTestAudiobook(fileSize: 500_000_000) // Large file = more chunks

        Task {
            try? await manager.uploadAudiobook(audiobook)
        }

        // Wait for upload to start
        try await Task.sleep(nanoseconds: 50_000_000)

        // Cancel transfer
        manager.cancelTransfer(audiobookId: audiobook.id)

        // Verify cancelled
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(manager.activeUploads[audiobook.id] == nil)
    }

    @Test("Handle corrupted file during cache")
    func handleCorruptedFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        // Point to non-existent file
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.m4b")

        #expect(throws: Error.self) {
            _ = try manager.cacheAudiobook(audiobook, from: fakeURL)
        }
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

        for i in 0..<1000 {
            let audiobook = createTestAudiobook(title: "Book \(i)")
            context.insert(audiobook)
        }

        try context.save()

        let startTime = Date()

        let descriptor = FetchDescriptor<Audiobook>()
        let results = try context.fetch(descriptor)

        let duration = Date().timeIntervalSince(startTime)

        #expect(results.count == 1000)
        #expect(duration < 1.0)
    }

    @Test("Progress update frequency")
    func progressUpdateFrequency() async throws {
        let manager = MockCloudKitTransferManager()
        manager.networkDelayNanoseconds = 10_000_000

        let audiobook = createTestAudiobook(fileSize: 100_000_000)

        var updateCount = 0

        Task {
            while manager.activeUploads[audiobook.id] != nil {
                updateCount += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        try await manager.uploadAudiobook(audiobook)

        #expect(updateCount > 0)
        #expect(updateCount < 1000)
    }
}
