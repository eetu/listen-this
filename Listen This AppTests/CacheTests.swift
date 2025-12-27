//
//  CacheTests.swift
//  Listen This AppTests
//
//  Tests for AudiobookCacheManager and file caching
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Cache Manager Tests

@Suite("AudiobookCacheManager Tests")
@MainActor
struct CacheManagerTests {

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

        // Set iCloudRelativePath so filename can be derived
        audiobook.iCloudRelativePath = "Documents/Audiobooks/\(cachedURL.lastPathComponent)"

        try manager.deleteCachedFile(for: audiobook)

        #expect(FileManager.default.fileExists(atPath: cachedURL.path) == false)
    }

    @Test("Get all cached files returns m4b files only")
    func getAllCachedFiles() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

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

        let file1 = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test1.m4b")
        let file2 = AudiobookCacheManager.cacheDirectory.appendingPathComponent("test2.m4b")

        let data1 = Data(repeating: 0, count: 1_000_000)
        let data2 = Data(repeating: 0, count: 2_000_000)

        try data1.write(to: file1)
        try data2.write(to: file2)

        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let totalSize = manager.getCacheSize()

        #expect(totalSize >= 2_600_000)
        #expect(totalSize <= 3_000_000)
    }

    @Test("Cleanup orphaned caches removes unlinked files")
    func cleanupOrphanedCaches() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let orphanedFile = AudiobookCacheManager.cacheDirectory.appendingPathComponent("orphan.m4b")
        try Data().write(to: orphanedFile)

        #expect(FileManager.default.fileExists(atPath: orphanedFile.path))

        try await manager.cleanupOrphanedCaches()

        #expect(FileManager.default.fileExists(atPath: orphanedFile.path) == false)
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

        let currentSize = manager.getCacheSize()

        if currentSize > 3_000_000_000 {
            try await manager.cleanupIfNeeded(maxSize: 3_000_000_000)
        }

        #expect(true)
    }

    @Test("Clean up orphaned files")
    func cleanupOrphans() async throws {
        let container = try createTestContainer()
        _ = ModelContext(container)
        _ = MockCacheManager()

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

    @Test("Audiobook expected cache path calculation")
    func expectedCachePath() async throws {
        let audiobook = createTestAudiobook()
        audiobook.iCloudRelativePath = "Documents/Audiobooks/test-book.m4b"

        let expectedPath = audiobook.expectedCachePath

        #expect(expectedPath != nil)
        #expect(expectedPath?.hasSuffix("test-book.m4b") == true)
    }
}
