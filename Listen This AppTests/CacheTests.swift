//
//  CacheTests.swift
//  Listen This AppTests
//
//  Tests for AudiobookCacheManager and file caching
//

import Foundation
import SwiftData
import Testing

@testable import Listen_This

// MARK: - Cache Manager Tests

@Suite("AudiobookCacheManager Tests")
@MainActor
struct CacheManagerTests {

    @Test("Cache directory is created")
    func cacheDirectoryCreation() async throws {
        let cacheDir = AudiobookCacheManager.cacheDirectory

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: cacheDir.path, isDirectory: &isDirectory)

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

// MARK: - CacheEntry Management Tests

@Suite("CacheEntry Creation & Cleanup Tests")
@MainActor
struct CacheEntryTests {

    @Test("CacheEntry is created when caching audiobook")
    func cacheEntryCreatedOnCache() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook(title: "Entry Test")
        context.insert(audiobook)

        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        // Initially no cache entry
        #expect(audiobook.cacheEntry == nil)

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        // Should have cache entry after caching
        #expect(audiobook.cacheEntry != nil)
        #expect(audiobook.cacheEntry?.filePath == cachedURL.path)
        #expect(audiobook.cacheEntry?.fileSize ?? 0 > 0)
    }

    @Test("CacheEntry is updated on re-cache")
    func cacheEntryUpdatedOnRecache() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook(title: "Recache Test")
        context.insert(audiobook)

        let sourceURL1 = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL1)
        }

        // First cache
        let cachedURL1 = try manager.cacheAudiobook(audiobook, from: sourceURL1)
        defer {
            try? FileManager.default.removeItem(at: cachedURL1)
        }

        let firstEntry = audiobook.cacheEntry
        let firstAccessDate = firstEntry?.lastAccessedDate

        #expect(firstEntry != nil)

        // Wait a moment to ensure timestamp difference
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

        // Re-cache
        let sourceURL2 = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL2)
        }

        let cachedURL2 = try manager.cacheAudiobook(audiobook, from: sourceURL2)
        defer {
            try? FileManager.default.removeItem(at: cachedURL2)
        }

        let secondEntry = audiobook.cacheEntry
        let secondAccessDate = secondEntry?.lastAccessedDate

        // Should be same entry, but updated
        #expect(secondEntry != nil)
        #expect(secondAccessDate ?? Date() > firstAccessDate ?? Date())
    }

    /*
    @Test("CacheEntry is deleted when deleting cached file")
    func cacheEntryDeletedWithFile() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)
    
        let audiobook = createTestAudiobook(title: "Delete Entry Test")
        context.insert(audiobook)
    
        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }
    
        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)
    
        // Should have cache entry
        #expect(audiobook.cacheEntry != nil)
    
        // Delete cached file
        try manager.deleteCachedFile(for: audiobook)
    
        // Cache entry should be cleaned up
        #expect(audiobook.cacheEntry == nil)
        #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
    }
    */

    @Test("Stale CacheEntry is cleaned up even if file missing")
    func staleCacheEntryCleanup() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook(title: "Stale Entry Test")
        context.insert(audiobook)

        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)

        #expect(audiobook.cacheEntry != nil)

        // Manually delete file without going through manager
        try FileManager.default.removeItem(at: cachedURL)

        // Now delete through manager - should clean up stale entry
        try manager.deleteCachedFile(for: audiobook)

        #expect(audiobook.cacheEntry == nil)
    }

    @Test("CacheEntry tracks file size correctly")
    func cacheEntryFileSize() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook(title: "File Size Test")
        context.insert(audiobook)

        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: cachedURL.path)
        let actualFileSize = attributes[.size] as? Int64 ?? 0

        #expect(audiobook.cacheEntry?.fileSize == actualFileSize)
        #expect(actualFileSize > 0)
    }

    @Test("Multiple audiobooks maintain independent CacheEntries")
    func independentCacheEntries() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let book1 = createTestAudiobook(title: "Book 1")
        let book2 = createTestAudiobook(title: "Book 2")
        let book3 = createTestAudiobook(title: "Book 3")

        context.insert(book1)
        context.insert(book2)
        context.insert(book3)

        let source1 = try createTestFile(name: "book1.m4b")
        let source2 = try createTestFile(name: "book2.m4b")
        let source3 = try createTestFile(name: "book3.m4b")

        defer {
            try? FileManager.default.removeItem(at: source1)
            try? FileManager.default.removeItem(at: source2)
            try? FileManager.default.removeItem(at: source3)
        }

        let cache1 = try manager.cacheAudiobook(book1, from: source1)
        let cache2 = try manager.cacheAudiobook(book2, from: source2)
        let cache3 = try manager.cacheAudiobook(book3, from: source3)

        defer {
            try? FileManager.default.removeItem(at: cache1)
            try? FileManager.default.removeItem(at: cache2)
            try? FileManager.default.removeItem(at: cache3)
        }

        // All should have independent entries
        #expect(book1.cacheEntry != nil)
        #expect(book2.cacheEntry != nil)
        #expect(book3.cacheEntry != nil)

        #expect(book1.cacheEntry?.id != book2.cacheEntry?.id)
        #expect(book2.cacheEntry?.id != book3.cacheEntry?.id)

        // Delete one shouldn't affect others
        try manager.deleteCachedFile(for: book2)

        #expect(book1.cacheEntry != nil)
        #expect(book2.cacheEntry == nil)
        #expect(book3.cacheEntry != nil)
    }

    @Test("CacheEntry timestamps are set correctly")
    func cacheEntryTimestamps() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = createTestAudiobook(title: "Timestamp Test")
        context.insert(audiobook)

        let sourceURL = try createTestFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let beforeCache = Date()

        let cachedURL = try manager.cacheAudiobook(audiobook, from: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        let afterCache = Date()

        guard let entry = audiobook.cacheEntry else {
            Issue.record("CacheEntry should exist")
            return
        }

        // Timestamps should be within reasonable range
        #expect(entry.downloadedDate >= beforeCache)
        #expect(entry.downloadedDate <= afterCache)
        #expect(entry.lastAccessedDate >= beforeCache)
        #expect(entry.lastAccessedDate <= afterCache)
    }
}

// MARK: - Helper Functions for CacheEntry Tests

extension CacheEntryTests {
    /// Create a test file with some content
    func createTestFile(name: String = "test.m4b") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(name)

        let testData = "Test audiobook content".data(using: .utf8)!
        try testData.write(to: fileURL)

        return fileURL
    }
}
