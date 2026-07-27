//
//  AudiobookshelfDownloadTests.swift
//  Listen This AppTests
//
//  Tests for downloading audiobooks directly from an Audiobookshelf server
//

import Foundation
import SwiftData
import Testing

@testable import Listen_This

// MARK: - Server Address Classification

@Suite("Audiobookshelf Server Address")
struct ABSServerAddressTests {

    @Test(
        "Cleartext is permitted on local addresses",
        arguments: [
            "http://192.168.1.5:13378",
            "http://10.0.0.2",
            "http://172.16.0.9",
            "http://172.31.255.1",
            "http://169.254.1.1",
            "http://127.0.0.1:13378",
            "http://localhost:13378",
            "http://nas.local",
            "http://audiobookshelf",
            "http://[fd00::1]",
        ]
    )
    func cleartextPermittedLocally(address: String) {
        #expect(ABSServerAddress.isCleartextPermitted(address))
    }

    @Test(
        "Cleartext is blocked on public addresses",
        arguments: [
            "http://abs.example.com",
            "http://audiobooks.duckdns.org:13378",
            "http://8.8.8.8",
            // 172.32 is outside the private 172.16/12 block
            "http://172.32.0.1",
            "http://172.15.0.1",
        ]
    )
    func cleartextBlockedPublicly(address: String) {
        #expect(!ABSServerAddress.isCleartextPermitted(address))
    }

    @Test(
        "HTTPS is always permitted",
        arguments: ["https://abs.example.com", "https://192.168.1.5:13378"]
    )
    func httpsAlwaysPermitted(address: String) {
        #expect(ABSServerAddress.isCleartextPermitted(address))
    }

    @Test("Unparseable addresses are not flagged")
    func unparseableAddressNotFlagged() {
        #expect(ABSServerAddress.isCleartextPermitted("not a url"))
    }
}

// MARK: - Error Mapping

@Suite("Audiobookshelf Error Mapping")
struct AudiobookshelfErrorMappingTests {

    @Test("App Transport Security failures map to a cleartext message")
    func mapsATSFailure() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection
        )

        guard case .cleartextBlocked = AudiobookshelfError.from(error) else {
            Issue.record("Expected .cleartextBlocked")
            return
        }
    }

    @Test(
        "Connection failures map to an unreachable message",
        arguments: [
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed,
        ]
    )
    func mapsConnectionFailures(code: Int) {
        let error = NSError(domain: NSURLErrorDomain, code: code)

        guard case .serverUnreachable = AudiobookshelfError.from(error) else {
            Issue.record("Expected .serverUnreachable for code \(code)")
            return
        }
    }

    @Test("Existing Audiobookshelf errors pass through unchanged")
    func passesThroughOwnErrors() {
        guard case .noToken = AudiobookshelfError.from(AudiobookshelfError.noToken) else {
            Issue.record("Expected .noToken")
            return
        }
    }
}

// MARK: - Byte-Based Progress

@Suite("Single-Stream Transfer Progress")
struct ByteProgressTests {

    private func makeProgress(bytesTransferred: Int64) -> ChunkTransferProgress {
        ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 1000,
            totalChunks: 1,
            completedChunks: 0,
            bytesTransferred: bytesTransferred,
            isUploading: false,
            usesByteProgress: true
        )
    }

    @Test("Progress starts at zero")
    func startsAtZero() {
        #expect(makeProgress(bytesTransferred: 0).progress == 0)
    }

    @Test("Progress tracks bytes rather than chunks")
    func tracksBytes() {
        let progress = makeProgress(bytesTransferred: 250)
        #expect(progress.progress == 0.25)
        #expect(progress.progressPercentage == 25)
    }

    @Test("Progress clamps at 100 percent")
    func clampsAtFull() {
        // A server can send slightly more than the size we had on record.
        #expect(makeProgress(bytesTransferred: 1200).progress == 1.0)
    }

    @Test("Status text omits chunk wording")
    func statusTextOmitsChunks() {
        #expect(makeProgress(bytesTransferred: 100).statusText == "Downloading")
    }

    @Test("A near-instant sample can't invent an absurd transfer rate")
    func rejectsMicrosecondSamples() {
        var progress = makeProgress(bytesTransferred: 0)

        // Two callbacks a few microseconds apart, as URLSession delivers them.
        // Naively dividing 64 KB by ~0 seconds is what produced "4.5 GB/s".
        progress.lastUpdateTime = Date()
        progress.updateProgress(completedChunks: 0, bytesTransferred: 65_536)

        #expect(progress.currentSpeedBytesPerSecond < 100_000_000)
        #expect(progress.bytesTransferred == 65_536)
    }

    @Test("A realistic sample window yields a sane rate")
    func computesRateOverRealWindow() {
        var progress = makeProgress(bytesTransferred: 0)

        // 1 MB delivered over half a second ≈ 2 MB/s.
        progress.lastUpdateTime = Date().addingTimeInterval(-0.5)
        progress.updateProgress(completedChunks: 0, bytesTransferred: 1_000_000)

        let speed = progress.currentSpeedBytesPerSecond
        #expect(speed > 1_000_000)
        #expect(speed < 4_000_000)
    }

    @Test("Speed averaging damps a sudden burst")
    func smoothsBursts() {
        var progress = makeProgress(bytesTransferred: 0)

        // Establish a steady ~2 MB/s.
        for step in 1...4 {
            progress.lastUpdateTime = Date().addingTimeInterval(-0.5)
            progress.updateProgress(
                completedChunks: 0, bytesTransferred: Int64(step) * 1_000_000)
        }
        let steady = progress.currentSpeedBytesPerSecond

        // A single 10x burst must nudge the reading, not redefine it.
        progress.lastUpdateTime = Date().addingTimeInterval(-0.5)
        progress.updateProgress(completedChunks: 0, bytesTransferred: 14_000_000)

        #expect(progress.currentSpeedBytesPerSecond < steady * 3)
    }

    @Test("Chunked progress is unaffected")
    func chunkedProgressUnchanged() {
        let progress = ChunkTransferProgress(
            audiobookId: UUID(),
            totalBytes: 1000,
            totalChunks: 4,
            completedChunks: 1,
            bytesTransferred: 999,
            isUploading: false
        )

        #expect(progress.progress == 0.25)
        #expect(progress.statusText == "Downloading chunk 2 of 4")
    }
}

// MARK: - Transfer Progress Centre

@Suite("Transfer Progress Centre")
@MainActor
struct TransferProgressCenterTests {

    @Test("Reported fractions are readable by id")
    func reportsFraction() {
        let center = TransferProgressCenter.shared
        let id = UUID()
        defer { center.finish(id) }

        center.report(id, fraction: 0.42)
        #expect(center.fraction(for: id) == 0.42)
    }

    @Test("Fractions clamp to 0...1")
    func clampsFraction() {
        let center = TransferProgressCenter.shared
        let low = UUID()
        let high = UUID()
        defer {
            center.finish(low)
            center.finish(high)
        }

        center.report(low, fraction: -3)
        center.report(high, fraction: 8)

        #expect(center.fraction(for: low) == 0)
        #expect(center.fraction(for: high) == 1)
    }

    @Test("A byte report with an unknown total is ignored")
    func ignoresUnknownTotal() {
        let center = TransferProgressCenter.shared
        let id = UUID()
        defer { center.finish(id) }

        // Showing 0% because the size isn't known yet would be misleading.
        center.report(id, bytesTransferred: 500, totalBytes: 0)
        #expect(center.fraction(for: id) == nil)
    }

    @Test("Byte reports convert to a fraction")
    func convertsBytes() {
        let center = TransferProgressCenter.shared
        let id = UUID()
        defer { center.finish(id) }

        center.report(id, bytesTransferred: 250, totalBytes: 1_000)
        #expect(center.fraction(for: id) == 0.25)
    }

    @Test("Finishing clears the entry so no stale ring is drawn")
    func finishClears() {
        let center = TransferProgressCenter.shared
        let id = UUID()

        center.report(id, fraction: 0.9)
        center.finish(id)

        #expect(center.fraction(for: id) == nil)
    }

    @Test("A non-finite fraction is rejected")
    func rejectsNonFinite() {
        let center = TransferProgressCenter.shared
        let id = UUID()
        defer { center.finish(id) }

        center.report(id, fraction: .nan)
        #expect(center.fraction(for: id) == nil)
    }
}

// MARK: - Download Bookkeeping

@Suite("Audiobookshelf Download Manager")
@MainActor
struct AudiobookshelfDownloadManagerTests {

    private func makeAudiobookshelfBook(fileSize: Int64 = 1_000) -> Audiobook {
        let audiobook = Audiobook(
            title: "Server Book",
            author: "Test Author",
            duration: 3600,
            fileSize: fileSize
        )
        audiobook.sourceType = "audiobookshelf"
        audiobook.sourceIdentifier = "li_\(UUID().uuidString)"
        return audiobook
    }

    @Test("Completed download creates a cache entry and reads as cached")
    func recordsCacheEntry() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = makeAudiobookshelfBook()
        context.insert(audiobook)

        // Write the file where the app expects the cached copy to live, so the
        // filesystem-backed playability check sees it.
        let cachePath = try #require(audiobook.expectedCachePath)
        let cacheURL = URL(fileURLWithPath: cachePath)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 2_048).write(to: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        #expect(audiobook.cacheEntry == nil)

        try AudiobookshelfDownloadManager.shared.recordCompletedDownload(
            for: audiobook,
            at: cacheURL,
            in: context
        )

        let entry = try #require(audiobook.cacheEntry)
        #expect(entry.filePath == cachePath)
        #expect(entry.fileSize == 2_048)
        #expect(audiobook.playabilityState == .cached)
    }

    @Test("Recording twice updates the existing entry instead of duplicating")
    func updatesExistingEntry() throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = makeAudiobookshelfBook()
        context.insert(audiobook)

        let cachePath = try #require(audiobook.expectedCachePath)
        let cacheURL = URL(fileURLWithPath: cachePath)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: 1_024).write(to: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let manager = AudiobookshelfDownloadManager.shared
        try manager.recordCompletedDownload(for: audiobook, at: cacheURL, in: context)
        let firstEntry = try #require(audiobook.cacheEntry)

        try Data(repeating: 7, count: 4_096).write(to: cacheURL)
        try manager.recordCompletedDownload(for: audiobook, at: cacheURL, in: context)

        let entries = try context.fetch(FetchDescriptor<CacheEntry>())
        #expect(entries.count == 1)
        #expect(audiobook.cacheEntry === firstEntry)
        #expect(audiobook.cacheEntry?.fileSize == 4_096)
    }

    @Test("Free space check rejects a file larger than the disk")
    func rejectsOversizedDownload() {
        let directory = FileManager.default.temporaryDirectory

        #expect(throws: AudiobookshelfDownloadError.self) {
            // Far beyond any plausible free space, including CI machines.
            try AudiobookshelfDownloadManager.verifyFreeSpace(
                for: Int64.max / 2,
                in: directory
            )
        }
    }

    @Test("Free space check passes for a small file")
    func acceptsSmallDownload() throws {
        try AudiobookshelfDownloadManager.verifyFreeSpace(
            for: 1_024,
            in: FileManager.default.temporaryDirectory
        )
    }

    @Test("Download requires a source identifier")
    func requiresSourceIdentifier() async {
        let audiobook = Audiobook(title: "No Source", author: "Test", fileSize: 1_000)
        audiobook.sourceType = "audiobookshelf"

        await #expect(throws: AudiobookshelfDownloadError.self) {
            try await AudiobookshelfDownloadManager.shared.download(audiobook)
        }
    }
}
