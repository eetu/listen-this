//
//  PartialDownloadTests.swift
//  Listen This AppTests
//
//  A partial transfer must never present itself as a downloaded book
//

import Foundation
import SwiftData
import Testing

@testable import Listen_This

@Suite("Partial Download Handling")
@MainActor
struct PartialDownloadTests {

    /// Write `bytes` to the exact path the app treats as this book's cached copy.
    private func writeCacheFile(for audiobook: Audiobook, bytes: Int) throws -> URL {
        let path = try #require(audiobook.expectedCachePath)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 3, count: bytes).write(to: url)
        return url
    }

    private func makeBook(fileSize: Int64) -> Audiobook {
        let audiobook = Audiobook(
            title: "Partial Test",
            author: "Author",
            duration: 3600,
            fileSize: fileSize
        )
        audiobook.sourceType = "audiobookshelf"
        audiobook.sourceIdentifier = "li_\(UUID().uuidString)"
        return audiobook
    }

    @Test("A truncated leftover file is not adopted as a download")
    func rejectsPartialFile() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook(fileSize: 10_000)
        context.insert(audiobook)

        // Half the book — the shape of an interrupted transfer.
        let url = try writeCacheFile(for: audiobook, bytes: 5_000)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.adoptOrphanedCacheFileIfNeeded(for: audiobook) == false)
        #expect(audiobook.cacheEntry == nil)
    }

    @Test("A complete file is adopted")
    func adoptsCompleteFile() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook(fileSize: 10_000)
        context.insert(audiobook)

        let url = try writeCacheFile(for: audiobook, bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.adoptOrphanedCacheFileIfNeeded(for: audiobook) == true)
        #expect(audiobook.cacheEntry != nil)
    }

    @Test("Slight size drift is tolerated")
    func toleratesSmallDrift() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook(fileSize: 10_000)
        context.insert(audiobook)

        // 0.5% short — metadata drift, not a truncation.
        let url = try writeCacheFile(for: audiobook, bytes: 9_950)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.adoptOrphanedCacheFileIfNeeded(for: audiobook) == true)
    }

    @Test("A book with unknown size still adopts any non-empty file")
    func unknownSizeFallsBack() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook(fileSize: 0)
        context.insert(audiobook)

        let url = try writeCacheFile(for: audiobook, bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(manager.adoptOrphanedCacheFileIfNeeded(for: audiobook) == true)
    }

    @Test("File size helper reads the real size")
    func fileSizeHelper() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 2_048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(AudiobookshelfDownloadManager.fileSize(at: url) == 2_048)
    }

    @Test("File size helper returns nil for a missing file")
    func fileSizeHelperMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).missing")

        #expect(AudiobookshelfDownloadManager.fileSize(at: url) == nil)
    }
}
