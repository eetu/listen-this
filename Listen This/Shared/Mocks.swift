//
//  Mocks.swift
//  Listen This
//
//  Shared mock implementations for previews and testing
//  Available in DEBUG builds only
//
//  NOTE: For this file to work in tests, either:
//  1. Add all dependent source files to the test target, OR
//  2. Use @testable import in your test files
//

#if DEBUG

import Foundation
import SwiftData
import CloudKit
import Observation
import MediaPlayer
import WatchConnectivity

// MARK: - Mock CloudKit Transfer Manager

/// Mock implementation of CloudKit transfer manager for previews and testing
///
/// Usage in previews:
/// ```swift
/// #Preview {
///     let mock = MockCloudKitTransferManager()
///     mock.preloadUploadedBooks(["book-id-1", "book-id-2"])
///     return CloudKitTransferView()
///         .environment(mock)
/// }
/// ```
///
/// Usage in tests:
/// ```swift
/// let manager = MockCloudKitTransferManager()
/// manager.shouldFailUpload = true
/// try await manager.uploadAudiobook(audiobook)
/// ```
@MainActor
@Observable
final class MockCloudKitTransferManager: CloudKitTransferManager {

    // MARK: - Observable State

    var activeUploads: [UUID: ChunkTransferProgress] = [:]
    var activeDownloads: [UUID: ChunkTransferProgress] = [:]

    // MARK: - Test Configuration

    /// Set to true to simulate upload failures
    var shouldFailUpload = false

    /// Set to true to simulate download failures
    var shouldFailDownload = false

    /// Enable/disable network delay simulation
    var simulateNetworkDelay = true

    /// Network delay in nanoseconds (default: 100ms)
    var networkDelayNanoseconds: UInt64 = 100_000_000

    /// Simulate specific error
    var errorToThrow: ChunkTransferError?

    // MARK: - Internal State

    private var uploadedBooks: Set<UUID> = []
    private var uploadedChunks: [UUID: Set<Int>] = [:] // Track partial uploads

    // MARK: - Initializers

    init() {}

    /// Create a mock with pre-uploaded books (useful for previews)
    init(uploadedBooks: [UUID]) {
        self.uploadedBooks = Set(uploadedBooks)
    }

    // MARK: - CloudKitTransferManager Protocol

    func uploadAudiobook(_ audiobook: Audiobook) async throws {
        let audiobookId = audiobook.id

        // Check for configured errors
        if let error = errorToThrow {
            throw error
        }

        if shouldFailUpload {
            throw ChunkTransferError.networkError
        }

        // Calculate chunks
        let chunkCount = Int(ceil(Double(audiobook.fileSize) / Double(CloudKitChunkedTransferManager.chunkSize)))

        // Initialize progress
        var progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: audiobook.fileSize,
            totalChunks: chunkCount,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: true
        )
        activeUploads[audiobookId] = progress

        // Simulate chunk uploads
        let bytesPerChunk = audiobook.fileSize / Int64(chunkCount)
        for i in 1...chunkCount {
            // Check if cancelled
            guard activeUploads[audiobookId] != nil else {
                throw ChunkTransferError.incompleteUpload
            }

            if simulateNetworkDelay {
                try await Task.sleep(nanoseconds: networkDelayNanoseconds)
            }

            progress.completedChunks = i
            progress.bytesTransferred = Int64(i) * bytesPerChunk
            activeUploads[audiobookId] = progress
        }

        // Complete upload
        activeUploads.removeValue(forKey: audiobookId)
        uploadedBooks.insert(audiobookId)
        uploadedChunks[audiobookId] = Set(0..<chunkCount)
    }

    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL {
        let audiobookId = audiobook.id

        // Check for configured errors
        if let error = errorToThrow {
            throw error
        }

        if shouldFailDownload {
            throw ChunkTransferError.networkError
        }

        // Check if uploaded
        guard uploadedBooks.contains(audiobookId) else {
            throw ChunkTransferError.fileNotAvailable
        }

        // Calculate chunks
        let chunkCount = Int(ceil(Double(audiobook.fileSize) / Double(CloudKitChunkedTransferManager.chunkSize)))

        // Initialize progress
        var progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: audiobook.fileSize,
            totalChunks: chunkCount,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: false
        )
        activeDownloads[audiobookId] = progress

        // Simulate chunk downloads
        let bytesPerChunk = audiobook.fileSize / Int64(chunkCount)
        for i in 1...chunkCount {
            // Check if cancelled
            guard activeDownloads[audiobookId] != nil else {
                throw ChunkTransferError.incompleteUpload
            }

            if simulateNetworkDelay {
                try await Task.sleep(nanoseconds: networkDelayNanoseconds)
            }

            progress.completedChunks = i
            progress.bytesTransferred = Int64(i) * bytesPerChunk
            activeDownloads[audiobookId] = progress
        }

        // Complete download
        activeDownloads.removeValue(forKey: audiobookId)

        // Return mock URL
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(audiobookId).m4b")
    }

    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws {
        if let error = errorToThrow {
            throw error
        }

        uploadedBooks.remove(audiobook.id)
        uploadedChunks.removeValue(forKey: audiobook.id)

        if simulateNetworkDelay {
            try await Task.sleep(nanoseconds: networkDelayNanoseconds)
        }
    }

    func deleteAudiobookFromCloud(audiobookId: UUID) async throws {
        if let error = errorToThrow {
            throw error
        }

        uploadedBooks.remove(audiobookId)
        uploadedChunks.removeValue(forKey: audiobookId)

        if simulateNetworkDelay {
            try await Task.sleep(nanoseconds: networkDelayNanoseconds)
        }
    }

    func checkCloudKitChunks(for audiobook: Audiobook) async -> ChunkAvailability {
        let audiobookId = audiobook.id

        if let chunks = uploadedChunks[audiobookId] {
            let expectedChunks = Int(ceil(Double(audiobook.fileSize) / Double(CloudKitChunkedTransferManager.chunkSize)))

            if chunks.count == expectedChunks {
                return .fullyUploaded
            } else if !chunks.isEmpty {
                return .partiallyUploaded(existingChunks: chunks)
            }
        }

        return .notUploaded
    }

    func cancelTransfer(audiobookId: UUID) {
        activeUploads.removeValue(forKey: audiobookId)
        activeDownloads.removeValue(forKey: audiobookId)
    }

    // MARK: - Preview & Test Helpers

    /// Preload books as "uploaded" for previews
    func preloadUploadedBooks(_ audiobookIds: [UUID]) {
        uploadedBooks = Set(audiobookIds)
        for id in audiobookIds {
            uploadedChunks[id] = Set(0..<10) // Default 10 chunks
        }
    }

    /// Simulate partial upload for testing
    func simulatePartialUpload(_ audiobook: Audiobook, uploadedChunks chunks: Set<Int>) {
        let audiobookId = audiobook.id
        self.uploadedChunks[audiobookId] = chunks
    }

    /// Simulate active upload in progress (for previews)
    func simulateActiveUpload(audiobookId: UUID, progress: Double) {
        let totalChunks = 10
        let completedChunks = Int(Double(totalChunks) * progress)

        activeUploads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 100_000_000,
            totalChunks: totalChunks,
            completedChunks: completedChunks,
            bytesTransferred: Int64(Double(100_000_000) * progress),
            isUploading: true
        )
    }

    /// Simulate active download in progress (for previews)
    func simulateActiveDownload(audiobookId: UUID, progress: Double) {
        let totalChunks = 10
        let completedChunks = Int(Double(totalChunks) * progress)

        activeDownloads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 100_000_000,
            totalChunks: totalChunks,
            completedChunks: completedChunks,
            bytesTransferred: Int64(Double(100_000_000) * progress),
            isUploading: false
        )
    }

    /// Reset all state (useful between tests)
    func reset() {
        activeUploads.removeAll()
        activeDownloads.removeAll()
        uploadedBooks.removeAll()
        uploadedChunks.removeAll()
        shouldFailUpload = false
        shouldFailDownload = false
        simulateNetworkDelay = true
        networkDelayNanoseconds = 100_000_000
        errorToThrow = nil
    }
}

// MARK: - Mock Cache Manager

/// Mock implementation of cache manager for previews and testing
@MainActor
final class MockCacheManager: CacheManager {

    // MARK: - Static Properties

    static var cacheDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MockCache")
    }

    // MARK: - State

    var cachedAudiobooks: Set<String> = []
    var shouldFailCaching = false
    var errorToThrow: Error?

    // MARK: - Initializers

    init() {}

    init(cachedAudiobooks: [String]) {
        self.cachedAudiobooks = Set(cachedAudiobooks)
    }

    // MARK: - CacheManager Protocol

    func cacheAudiobook(_ audiobook: Audiobook, from sourceURL: URL) throws -> URL {
        if let error = errorToThrow {
            throw error
        }

        if shouldFailCaching {
            throw NSError(domain: "MockCacheManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Mock caching failure"
            ])
        }

        cachedAudiobooks.insert(audiobook.id.uuidString)
        let cacheURL = Self.cacheDirectory.appendingPathComponent(audiobook.id.uuidString + ".m4b")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)

        // Copy file (if source exists)
        try? FileManager.default.removeItem(at: cacheURL)
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try FileManager.default.copyItem(at: sourceURL, to: cacheURL)
        }

        return cacheURL
    }

    func deleteCachedFile(for audiobook: Audiobook) throws {
        cachedAudiobooks.remove(audiobook.id.uuidString)

        if let cachePath = audiobook.expectedCachePath {
            let cacheURL = URL(fileURLWithPath: cachePath)
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    func getAllCachedFiles() -> [URL] {
        let cacheDir = Self.cacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return files.filter { $0.pathExtension == "m4b" }
    }

    func getCacheSize() -> Int64 {
        // Mock: 50MB per book
        return Int64(cachedAudiobooks.count) * 50_000_000
    }

    func cleanupOrphanedCaches() async throws {
        if let error = errorToThrow {
            throw error
        }
        // Mock implementation - no-op
    }

    func evictOldCaches(keepingCount: Int? = nil) async throws {
        if let error = errorToThrow {
            throw error
        }

        let count = keepingCount ?? 5
        // Mock: Remove oldest cached books beyond keepingCount
        if cachedAudiobooks.count > count {
            let toRemove = cachedAudiobooks.count - count
            let idsToRemove = Array(cachedAudiobooks.prefix(toRemove))
            idsToRemove.forEach { cachedAudiobooks.remove($0) }
        }
    }

    func cleanupIfNeeded(maxSize: Int64? = nil) async throws {
        if let error = errorToThrow {
            throw error
        }

        let limit = maxSize ?? 3_000_000_000
        let currentSize = getCacheSize()
        if currentSize > limit {
            // Mock: Remove books until under limit
            while getCacheSize() > limit && !cachedAudiobooks.isEmpty {
                if let first = cachedAudiobooks.first {
                    cachedAudiobooks.remove(first)
                }
            }
        }
    }

    // MARK: - Preview & Test Helpers

    /// Check if a specific audiobook is cached
    func isCached(_ audiobook: Audiobook) -> Bool {
        cachedAudiobooks.contains(audiobook.id.uuidString)
    }

    /// Preload cached audiobooks (for previews)
    func preloadCachedBooks(_ audiobookIds: [String]) {
        cachedAudiobooks = Set(audiobookIds)
    }

    /// Reset all state
    func reset() {
        cachedAudiobooks.removeAll()
        shouldFailCaching = false
        errorToThrow = nil
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }
}

#if os(iOS)

// MARK: - Mock iOS Watch Connectivity Manager

/// Mock implementation of iOS Watch Connectivity manager for previews and testing
@MainActor
@Observable
final class MockiOSWatchConnectivity: iOSWatchConnectivity {

    // MARK: - Observable State

    var isReachable = true
    var isPaired = true
    var isWatchAppInstalled = true
    var activeTransfers: [String: WatchTransferProgress] = [:]
    var watchCachedAudiobookIds: Set<String> = []
    var lastError: Error?
    var session: WCSession?

    // MARK: - Test Configuration

    var shouldFailTransfer = false
    var simulateNetworkDelay = true
    var networkDelayNanoseconds: UInt64 = 300_000_000 // 300ms

    // MARK: - Internal State

    private var modelContext: ModelContext?

    // MARK: - Initializers

    init() {}

    init(isReachable: Bool = true, isPaired: Bool = true, isWatchAppInstalled: Bool = true) {
        self.isReachable = isReachable
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
    }

    // MARK: - iOSWatchConnectivity Protocol

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func transferAudiobook(_ audiobook: Audiobook) async throws {
        if shouldFailTransfer {
            throw WatchTransferError.transferFailed
        }

        let audiobookId = audiobook.id.uuidString

        // Initialize progress
        var progress = WatchTransferProgress(
            audiobookId: audiobookId,
            audiobookTitle: audiobook.title,
            totalBytes: audiobook.fileSize,
            bytesTransferred: 0,
            isActive: true
        )
        activeTransfers[audiobookId] = progress

        // Simulate progressive transfer
        let steps = 10
        let bytesPerStep = audiobook.fileSize / Int64(steps)

        for i in 1...steps {
            if simulateNetworkDelay {
                try await Task.sleep(nanoseconds: networkDelayNanoseconds)
            }

            // Check if cancelled
            guard activeTransfers[audiobookId] != nil else {
                throw WatchTransferError.transferFailed
            }

            progress.bytesTransferred = Int64(i) * bytesPerStep
            activeTransfers[audiobookId] = progress
        }

        // Complete transfer
        activeTransfers.removeValue(forKey: audiobookId)
        watchCachedAudiobookIds.insert(audiobookId)
    }

    func cancelTransfer(for audiobookId: String) {
        activeTransfers.removeValue(forKey: audiobookId)
    }

    func requestWatchCachedList() {
        // Mock implementation - no-op
    }

    func checkOutstandingTransfers() {
        // Mock implementation - no-op
    }

    // MARK: - Preview & Test Helpers

    /// Simulate active transfer at specific progress (for previews)
    func simulateActiveTransfer(audiobook: Audiobook, progress: Double) {
        let audiobookId = audiobook.id.uuidString
        let transferProgress = WatchTransferProgress(
            audiobookId: audiobookId,
            audiobookTitle: audiobook.title,
            totalBytes: audiobook.fileSize,
            bytesTransferred: Int64(Double(audiobook.fileSize) * progress),
            isActive: true
        )
        activeTransfers[audiobookId] = transferProgress
    }

    /// Preload cached audiobooks on watch (for previews)
    func preloadWatchCachedBooks(_ audiobookIds: [String]) {
        watchCachedAudiobookIds = Set(audiobookIds)
    }

    /// Reset all state
    func reset() {
        activeTransfers.removeAll()
        watchCachedAudiobookIds.removeAll()
        lastError = nil
        shouldFailTransfer = false
        simulateNetworkDelay = true
        isReachable = true
        isPaired = true
        isWatchAppInstalled = true
    }
}

#endif // os(iOS)

// MARK: - Mock Audio Player Service

/// Mock implementation of audio player service for previews and testing
@MainActor
@Observable
final class MockAudioPlayerService: AudioPlayer {

    // MARK: - Observable State

    var isPlaying: Bool
    var currentPosition: Double
    var duration: Double
    var playbackRate: Double
    var currentChapterIndex: Int
    var loadError: Error?
    var sleepTimerRemaining: TimeInterval
    var isSleepTimerActive: Bool
    var sortedChapters: [Chapter]

    // MARK: - Initializers

    init(
        isPlaying: Bool = false,
        currentPosition: Double = 0,
        duration: Double = 3600,
        playbackRate: Double = 1.0,
        currentChapterIndex: Int = 0,
        loadError: Error? = nil,
        sleepTimerRemaining: TimeInterval = 0,
        isSleepTimerActive: Bool = false,
        sortedChapters: [Chapter] = []
    ) {
        self.isPlaying = isPlaying
        self.currentPosition = currentPosition
        self.duration = duration
        self.playbackRate = playbackRate
        self.currentChapterIndex = currentChapterIndex
        self.loadError = loadError
        self.sleepTimerRemaining = sleepTimerRemaining
        self.isSleepTimerActive = isSleepTimerActive
        self.sortedChapters = sortedChapters
    }

    // MARK: - AudioPlayer Protocol

    func load(audiobook: Audiobook) async {
        duration = audiobook.duration
        currentPosition = 0
        currentChapterIndex = 0
        sortedChapters = audiobook.chapters?.sorted { $0.index < $1.index } ?? []
    }

    func play() async {
        isPlaying = true
    }

    func pause() async {
        isPlaying = false
    }

    func seek(to position: Double) async -> Double {
        currentPosition = min(max(0, position), duration)
        return currentPosition
    }

    func skip(by seconds: Double) async {
        currentPosition = min(max(0, currentPosition + seconds), duration)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
    }

    func previousChapter() async {
        if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            if currentChapterIndex < sortedChapters.count {
                currentPosition = sortedChapters[currentChapterIndex].startTime
            }
        }
    }

    func nextChapter() async {
        if currentChapterIndex < sortedChapters.count - 1 {
            currentChapterIndex += 1
            currentPosition = sortedChapters[currentChapterIndex].startTime
        }
    }

    func setSleepTimer(minutes: Int) {
        isSleepTimerActive = true
        sleepTimerRemaining = TimeInterval(minutes * 60)
    }

    func cancelSleepTimer() {
        isSleepTimerActive = false
        sleepTimerRemaining = 0
    }
}

// MARK: - Mock Data Helpers

/// Helper functions to create mock data for previews and tests
extension Audiobook {

    /// Create a sample audiobook for previews
    static func preview(
        title: String = "The Hobbit",
        author: String = "J.R.R. Tolkien",
        narrator: String = "Andy Serkis",
        duration: Double = 11 * 3600, // 11 hours
        fileSize: Int64 = 450_000_000 // 450MB
    ) -> Audiobook {
        let audiobook = Audiobook(
            title: title,
            author: author,
            narrator: narrator,
            duration: duration,
            fileSize: fileSize
        )
        audiobook.localFilename = "\(title.replacingOccurrences(of: " ", with: "_")).m4b"
        audiobook.chapterCount = 19

        return audiobook
    }

    /// Create multiple sample audiobooks for previews
    static func previewLibrary() -> [Audiobook] {
        return [
            .preview(title: "The Hobbit", author: "J.R.R. Tolkien", narrator: "Andy Serkis"),
            .preview(title: "Harry Potter and the Philosopher's Stone", author: "J.K. Rowling", narrator: "Stephen Fry"),
            .preview(title: "1984", author: "George Orwell", narrator: "Simon Prebble"),
            .preview(title: "The Great Gatsby", author: "F. Scott Fitzgerald", narrator: "Jake Gyllenhaal"),
            .preview(title: "To Kill a Mockingbird", author: "Harper Lee", narrator: "Sissy Spacek")
        ]
    }
}

extension Chapter {

    /// Create a sample chapter for previews
    static func preview(
        index: Int = 0,
        title: String = "Chapter 1",
        startTime: Double = 0,
        duration: Double = 1800 // 30 minutes
    ) -> Chapter {
        Chapter(
            index: index,
            title: title,
            startTime: startTime,
            duration: duration
        )
    }

    /// Create sample chapters for a book
    static func previewChapters(count: Int = 10) -> [Chapter] {
        return (0..<count).map { i in
            Chapter.preview(
                index: i,
                title: "Chapter \(i + 1)",
                startTime: Double(i * 1800),
                duration: 1800
            )
        }
    }
}

// MARK: - SwiftData Preview Container Helper

@MainActor
func createPreviewContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self,
        configurations: config
    )

    // Populate with sample data
    let context = ModelContext(container)
    let audiobooks = Audiobook.previewLibrary()

    for audiobook in audiobooks {
        context.insert(audiobook)

        // Add chapters to first audiobook
        if audiobook.title == "The Hobbit" {
            let chapters = Chapter.previewChapters(count: 19)
            audiobook.chapters = chapters
            chapters.forEach { context.insert($0) }
        }
    }

    try context.save()

    return container
}

#endif
