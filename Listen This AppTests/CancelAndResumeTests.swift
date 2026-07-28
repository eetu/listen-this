//
//  CancelAndResumeTests.swift
//  Listen This AppTests
//
//  Cancelling should give the space back; an interruption should not.
//

import Foundation
import SwiftData
import Testing

@testable import Listen_This

// MARK: - Chunk Resume Offset

@Suite("Chunk Resume Offset")
struct ChunkResumeOffsetTests {

    private let chunkSize = CloudKitChunkedTransferManager.chunkSize

    private func makeFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4b")
        // Sparse file: allocating hundreds of megabytes for real would make the
        // suite crawl, and only the reported size matters here.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @Test("A whole number of chunks resumes from that chunk")
    func resumesOnChunkBoundary() throws {
        let url = try makeFile(bytes: chunkSize * 2)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            CloudKitChunkedTransferManager.resumableChunkCount(at: url, chunkCount: 5) == 2)
    }

    @Test("A partial chunk is not resumable")
    func rejectsPartialChunk() throws {
        // Resuming from a short tail would splice the next chunk into the
        // middle of the previous one and silently corrupt the audiobook.
        let url = try makeFile(bytes: chunkSize + 17)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            CloudKitChunkedTransferManager.resumableChunkCount(at: url, chunkCount: 5) == 0)
    }

    @Test("An empty or missing file starts from scratch")
    func startsFromScratch() throws {
        let empty = try makeFile(bytes: 0)
        defer { try? FileManager.default.removeItem(at: empty) }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4b")

        #expect(
            CloudKitChunkedTransferManager.resumableChunkCount(at: empty, chunkCount: 5) == 0)
        #expect(
            CloudKitChunkedTransferManager.resumableChunkCount(at: missing, chunkCount: 5) == 0)
    }

    @Test("A file already at full length is not a resume candidate")
    func fullFileIsNotResumable() throws {
        let url = try makeFile(bytes: chunkSize * 3)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            CloudKitChunkedTransferManager.resumableChunkCount(at: url, chunkCount: 3) == 0)
    }
}

// MARK: - Partials Never Look Downloaded

// Serialized: these share the one partials directory, and the sweep tests
// would otherwise delete files the other tests are asserting on.
@Suite("Partial Download Visibility", .serialized)
@MainActor
struct PartialVisibilityTests {

    private func makeBook() -> Audiobook {
        let audiobook = Audiobook(
            title: "Interrupted", author: "Author", duration: 3600, fileSize: 10_000)
        audiobook.sourceType = "audiobookshelf"
        audiobook.sourceIdentifier = "li_\(UUID().uuidString)"
        return audiobook
    }

    @Test("A partial lives outside the cache directory")
    func partialIsNotAtCachePath() throws {
        let audiobook = makeBook()

        let partial = try #require(audiobook.partialFileURL)
        let cachePath = try #require(audiobook.expectedCachePath)

        // Sharing the path is what made an interrupted transfer read as a
        // finished one, so they must never resolve to the same place.
        #expect(partial.path != cachePath)
        #expect(partial.deletingLastPathComponent().path
            != URL(fileURLWithPath: cachePath).deletingLastPathComponent().path)
    }

    @Test("Bytes from an interrupted transfer don't make a book playable")
    func partialIsNotPlayable() throws {
        let audiobook = makeBook()
        let partial = try #require(audiobook.partialFileURL)

        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_000).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        #expect(audiobook.hasPartialDownload)
        #expect(audiobook.partialDownloadSize == 4_000)
        // The whole point: still not cached, still not playable.
        #expect(!audiobook.isFileCached)
        #expect(audiobook.playabilityState != .cached)
    }

    @Test("No partial file means no partial state")
    func noPartialReportsNothing() throws {
        let audiobook = makeBook()

        #expect(!audiobook.hasPartialDownload)
        #expect(audiobook.partialDownloadSize == nil)
    }

    @Test("A partial whose book left the library is reclaimed")
    func reclaimsOrphanedPartial() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let departed = makeBook()
        let partial = try #require(departed.partialFileURL)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        // The book is not in `audiobooks`, so its partial has nothing to resume.
        let (removed, freed) = manager.cleanupStalePartials(audiobooks: [])

        #expect(removed >= 1)
        #expect(freed >= 2_000)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("A partial for a book still in the library is kept")
    func keepsLivePartial() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook()
        context.insert(audiobook)
        let partial = try #require(audiobook.partialFileURL)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        manager.cleanupStalePartials(audiobooks: [audiobook])

        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test("A partial nobody came back for is reclaimed")
    func reclaimsStalePartial() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)
        let manager = AudiobookCacheManager(modelContext: context)

        let audiobook = makeBook()
        context.insert(audiobook)
        let partial = try #require(audiobook.partialFileURL)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        // Sweep as if well past the retention window rather than back-dating
        // the file and depending on filesystem timestamps.
        let future = Date().addingTimeInterval(AudiobookCacheManager.partialLifetime + 60)
        manager.cleanupStalePartials(audiobooks: [audiobook], now: future)

        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}

// MARK: - Reclaiming Staged Chunks

@Suite("Redundant Staged Chunks")
struct RedundantStagedChunkTests {

    private let onWatch = "book-on-watch"
    private let notOnWatch = "book-not-on-watch"
    private let inFlight = "book-transferring"

    @Test("Chunks for a book the Watch already has are redundant")
    func reclaimsWhatTheWatchHas() {
        let redundant = CloudKitChunkedTransferManager.redundantStagedChunkIds(
            staged: [onWatch, notOnWatch],
            cachedOnWatch: [onWatch],
            transferring: []
        )

        #expect(redundant == [onWatch])
    }

    @Test("Chunks the Watch doesn't have are left alone")
    func keepsWhatTheWatchNeeds() {
        // These are the whole point of staging — deleting them would strand a
        // pending download.
        let redundant = CloudKitChunkedTransferManager.redundantStagedChunkIds(
            staged: [notOnWatch],
            cachedOnWatch: [],
            transferring: []
        )

        #expect(redundant.isEmpty)
    }

    @Test("Chunks for an in-flight transfer are never reclaimed")
    func skipsActiveTransfers() {
        // The Watch may report the book as cached from a previous copy while a
        // fresh transfer is reading these chunks.
        let redundant = CloudKitChunkedTransferManager.redundantStagedChunkIds(
            staged: [inFlight],
            cachedOnWatch: [inFlight],
            transferring: [inFlight]
        )

        #expect(redundant.isEmpty)
    }

    @Test("Nothing staged means nothing to do")
    func noStagedChunks() {
        #expect(
            CloudKitChunkedTransferManager.redundantStagedChunkIds(
                staged: [],
                cachedOnWatch: [onWatch, notOnWatch],
                transferring: []
            ).isEmpty
        )
    }
}

// MARK: - Resume Data Expiry

// Serialized: these share one on-disk resume directory, and the stale-sweep
// test would otherwise delete the other test's fresh file mid-run.
@Suite("Resume Data Expiry", .serialized)
struct ResumeDataExpiryTests {

    @Test("Fresh resume data survives the sweep")
    func keepsFreshData() throws {
        let id = UUID()
        let url = AudiobookshelfDownloadManager.resumeDataURL(for: id)
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        AudiobookshelfDownloadManager.discardStaleResumeData()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Resume data nobody came back for is discarded")
    func discardsStaleData() throws {
        let id = UUID()
        let url = AudiobookshelfDownloadManager.resumeDataURL(for: id)
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Sweep as if it were well past the retention window, rather than
        // back-dating the file and depending on filesystem timestamps.
        let future = Date().addingTimeInterval(
            AudiobookshelfDownloadManager.resumeDataLifetime + 60)
        AudiobookshelfDownloadManager.discardStaleResumeData(now: future)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
