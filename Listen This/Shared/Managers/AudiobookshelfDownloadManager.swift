//
//  AudiobookshelfDownloadManager.swift
//  Listen This
//
//  Downloads audiobooks straight from an Audiobookshelf server for offline
//  playback. Used by both iOS and watchOS, so the Watch can fetch a book over
//  WiFi without the iPhone acting as a middleman.
//

import Foundation
import OSLog
import Observation
import SwiftData

internal import os

// MARK: - Errors

enum AudiobookshelfDownloadError: LocalizedError {
    case notConfigured
    case missingIdentifier
    case alreadyInProgress
    case insufficientStorage
    case serverError(statusCode: Int)
    case fileMoveFailed(String)
    case truncated(received: Int64, expected: Int64)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Audiobookshelf isn't set up yet. Configure it on your iPhone in Settings."
        case .missingIdentifier:
            return "This book is missing its Audiobookshelf identifier."
        case .alreadyInProgress:
            return "This book is already downloading."
        case .insufficientStorage:
            return
                "Not enough free space on this device to download the audiobook. Free up space and try again."
        case .serverError(let statusCode):
            return "The server returned an error (HTTP \(statusCode))."
        case .fileMoveFailed(let message):
            return "Couldn't save the downloaded file: \(message)"
        case .truncated(let received, let expected):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return
                "The download finished short (\(formatter.string(fromByteCount: received)) of \(formatter.string(fromByteCount: expected))) and was discarded. Try again."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

// MARK: - Manager

/// Streams a single audiobook file from Audiobookshelf into the local cache.
///
/// Uses a background `URLSession` so a transfer survives the app being
/// backgrounded — essential on watchOS, where a multi-hundred-megabyte download
/// far outlives any foreground session. Progress is reported through the same
/// `ChunkTransferProgress` type the CloudKit transfers use, so both share one
/// progress UI.
@MainActor
@Observable
final class AudiobookshelfDownloadManager: NSObject, URLSessionDownloadDelegate {

    // MARK: - Shared Instance

    static let shared = AudiobookshelfDownloadManager()

    /// Identifier of the background session, so the watchOS extension delegate
    /// can tell our relaunch events apart from the CloudKit session's.
    static let sessionIdentifier = "com.anarkisti.ListenThis.audiobookshelf.download"

    /// Invoked once the background session has delivered every pending event.
    /// The watchOS extension delegate uses this to complete its refresh task at
    /// the right time instead of immediately.
    @ObservationIgnored
    static var backgroundEventsHandler: (() -> Void)?

    // MARK: - Observable State

    /// In-flight downloads keyed by audiobook id.
    var activeDownloads: [UUID: ChunkTransferProgress] = [:]

    // MARK: - Private State

    @ObservationIgnored private let logger = AppLogger.audiobookshelf
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<URL, Error>] = [:]
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]

    /// Why a transfer failed after the bytes arrived. Kept as a plain value so
    /// the record stays `Sendable` across the delegate queue.
    private enum TaskFailure: Sendable {
        case server(statusCode: Int)
        case fileMove(String)
        case truncated(received: Int64, expected: Int64)
    }

    /// Everything the (non-main) delegate queue needs to finish a transfer
    /// without touching main-actor state. Keyed by `taskDescription`, which we
    /// set to the audiobook's UUID string.
    private struct TaskRecord: Sendable {
        let audiobookId: UUID
        let destinationPath: String
        let expectedBytes: Int64
        var movedURL: URL?
        var failure: TaskFailure?
        /// When progress was last published to the UI, so the flood of
        /// `didWriteData` callbacks can be sampled rather than forwarded.
        var lastProgressUpdate: Date?
    }

    /// Minimum spacing between progress samples.
    ///
    /// `didWriteData` fires every few kilobytes. Publishing each one pegs the
    /// UI and, worse, makes the speed calculation divide by a near-zero time
    /// interval — which is what produced readings like 4.5 GB/s. Sampling twice
    /// a second gives the rate a meaningful window and keeps the display legible.
    nonisolated private static let progressSampleInterval: TimeInterval = 0.5

    @ObservationIgnored
    private let records = OSAllocatedUnfairLock(initialState: [String: TaskRecord]())

    /// Created lazily so simply referencing the manager (in tests, previews) does
    /// not register a background session with the system.
    @ObservationIgnored
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Same preference the CloudKit transfers honour: big transfers are
        // WiFi-only unless the user opted in.
        config.allowsCellularAccess = SettingsManager.shared.allowCellularForCloudKitTransfers
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // The reachability preflight already fails fast when the server isn't on
        // this network, so the resource timeout is a backstop rather than the
        // primary guard.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // Records outlive the process, so recover them before any delegate
        // callback for a transfer started in a previous launch arrives.
        restorePendingRecords()
    }

    // MARK: - Configuration

    /// Wire up the SwiftData context and re-establish the background session so
    /// it can deliver events for transfers started in a previous launch.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        _ = session
        Task { await adoptRunningTasks() }
    }

    /// Re-attach to transfers the system is still running.
    ///
    /// Background transfers continue in a separate process after the app is
    /// suspended or terminated, but `activeDownloads` lives in memory and is
    /// empty on relaunch. Without this the UI shows an idle Download button for
    /// a book that is already downloading, and tapping it starts a second
    /// transfer from zero.
    func adoptRunningTasks() async {
        let allTasks = await session.allTasks

        for task in allTasks {
            guard let downloadTask = task as? URLSessionDownloadTask,
                task.state == .running || task.state == .suspended,
                let key = task.taskDescription,
                let audiobookId = UUID(uuidString: key),
                let record = records.withLock({ $0[key] })
            else { continue }

            tasks[audiobookId] = downloadTask

            if activeDownloads[audiobookId] == nil {
                let expected =
                    task.countOfBytesExpectedToReceive > 0
                    ? task.countOfBytesExpectedToReceive
                    : record.expectedBytes

                activeDownloads[audiobookId] = ChunkTransferProgress(
                    audiobookId: audiobookId,
                    totalBytes: expected,
                    totalChunks: 1,
                    completedChunks: 0,
                    bytesTransferred: task.countOfBytesReceived,
                    isUploading: false,
                    usesByteProgress: true
                )

                TransferProgressCenter.shared.report(
                    audiobookId,
                    bytesTransferred: task.countOfBytesReceived,
                    totalBytes: expected
                )

                logger.info(
                    "Re-attached to in-flight Audiobookshelf download for \(audiobookId)")
            }
        }
    }

    /// Entry point for a background relaunch: recreates the session so it can
    /// deliver its queued events, and reports when it has finished doing so.
    ///
    /// The model context may still be nil at this point (the app was woken, not
    /// opened). The file is still moved into the cache, and the library heals
    /// the missing `CacheEntry` via `adoptOrphanedCacheFileIfNeeded` when the
    /// row next appears.
    func handleBackgroundSessionEvents(completion: @escaping () -> Void) {
        Self.backgroundEventsHandler = completion
        _ = session
        Task { await adoptRunningTasks() }
    }

    // MARK: - Queries

    func isDownloading(_ audiobookId: UUID) -> Bool {
        activeDownloads[audiobookId] != nil
    }

    /// Whether a partially completed transfer can be picked up where it stopped.
    func hasResumeData(for audiobookId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: Self.resumeDataURL(for: audiobookId).path)
    }

    // MARK: - Download

    /// Download `audiobook` from the configured server into the local cache.
    /// - Returns: the cached file URL once the `CacheEntry` has been recorded.
    @discardableResult
    func download(_ audiobook: Audiobook) async throws -> URL {
        let audiobookId = audiobook.id

        // Ask the system before starting anything: a transfer may still be
        // running from a previous launch, and starting a second one would throw
        // away its progress and begin again from zero.
        await adoptRunningTasks()

        guard !isDownloading(audiobookId) else {
            throw AudiobookshelfDownloadError.alreadyInProgress
        }

        guard let identifier = audiobook.sourceIdentifier, !identifier.isEmpty else {
            throw AudiobookshelfDownloadError.missingIdentifier
        }

        guard SettingsManager.shared.audiobookshelfIsConfigured else {
            throw AudiobookshelfDownloadError.notConfigured
        }

        guard let destinationPath = audiobook.expectedCachePath else {
            throw AudiobookshelfDownloadError.missingIdentifier
        }

        let destinationURL = URL(fileURLWithPath: destinationPath)
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        try Self.verifyFreeSpace(for: audiobook.fileSize, in: destinationDirectory)

        // Fail in seconds rather than sitting on a background session when the
        // server simply isn't on this network — the common case for a LAN-only
        // Audiobookshelf install.
        try await AudiobookshelfProvider.reachabilityCheck()

        let provider = try await AudiobookshelfProvider.authenticatedFromSettings()
        let downloadURL = try await provider.getDownloadURL(identifier: identifier)

        logger.info(
            "Starting Audiobookshelf download for '\(audiobook.title)' → \(destinationPath)")

        let record = TaskRecord(
            audiobookId: audiobookId,
            destinationPath: destinationPath,
            expectedBytes: audiobook.fileSize
        )
        records.withLock { $0[audiobookId.uuidString] = record }
        persistPendingRecords()

        activeDownloads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: audiobook.fileSize,
            totalChunks: 1,
            completedChunks: 0,
            isUploading: false,
            usesByteProgress: true
        )

        let task = makeTask(for: audiobookId, url: downloadURL)
        task.taskDescription = audiobookId.uuidString
        tasks[audiobookId] = task

        return try await withCheckedThrowingContinuation { continuation in
            continuations[audiobookId] = continuation
            task.resume()
        }
    }

    /// Resume a previously interrupted transfer when we still hold resume data,
    /// otherwise start fresh. Losing WiFi shouldn't cost the user a 300 MB
    /// re-download.
    private func makeTask(for audiobookId: UUID, url: URL) -> URLSessionDownloadTask {
        let resumeURL = Self.resumeDataURL(for: audiobookId)

        if let resumeData = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            logger.info("Resuming previous Audiobookshelf download for \(audiobookId)")
            return session.downloadTask(withResumeData: resumeData)
        }

        return session.downloadTask(with: url)
    }

    // MARK: - Cancel

    func cancel(audiobookId: UUID) {
        guard let task = tasks[audiobookId] else { return }

        logger.info("Cancelling Audiobookshelf download for \(audiobookId)")

        task.cancel { resumeData in
            guard let resumeData else { return }
            Self.storeResumeData(resumeData, for: audiobookId)
        }

        // The delegate's didCompleteWithError finishes the continuation; clear
        // the visible progress immediately so the UI reacts to the tap.
        activeDownloads.removeValue(forKey: audiobookId)
    }

    // MARK: - Completion

    /// Record the downloaded file so the rest of the app treats it as cached.
    ///
    /// Creating the `CacheEntry` is what makes a book read as "Downloaded" in
    /// the library and enables the Remove action — the previous in-player
    /// downloader skipped this, leaving downloads invisible to the UI.
    func recordCompletedDownload(
        for audiobook: Audiobook,
        at url: URL,
        in context: ModelContext
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? audiobook.fileSize

        if let existingEntry = audiobook.cacheEntry {
            existingEntry.filePath = url.path
            existingEntry.fileSize = fileSize
            existingEntry.lastAccessedDate = Date()
        } else {
            let cacheEntry = CacheEntry(
                filePath: url.path,
                fileSize: fileSize,
                downloadedDate: Date(),
                lastAccessedDate: Date()
            )
            cacheEntry.audiobook = audiobook
            audiobook.cacheEntry = cacheEntry
            context.insert(cacheEntry)
        }

        try context.save()
    }

    /// Terminal handler for a transfer. Also runs for downloads that completed
    /// while the app wasn't running, in which case there is no continuation to
    /// resume but the cache entry still needs recording.
    private func finish(audiobookId: UUID, result: Result<URL, Error>) {
        activeDownloads.removeValue(forKey: audiobookId)
        TransferProgressCenter.shared.finish(audiobookId)
        tasks.removeValue(forKey: audiobookId)
        records.withLock { _ = $0.removeValue(forKey: audiobookId.uuidString) }
        persistPendingRecords()

        let continuation = continuations.removeValue(forKey: audiobookId)

        switch result {
        case .success(let url):
            do {
                if let modelContext, let audiobook = fetchAudiobook(id: audiobookId) {
                    try recordCompletedDownload(for: audiobook, at: url, in: modelContext)
                    warnIfDuplicated(audiobook, in: modelContext)
                }
                logger.info("Audiobookshelf download complete: \(url.lastPathComponent)")
                continuation?.resume(returning: url)
            } catch {
                logger.error("Failed to record download: \(error.localizedDescription)")
                continuation?.resume(throwing: error)
            }

        case .failure(let error):
            logger.error("Audiobookshelf download failed: \(error.localizedDescription)")
            continuation?.resume(throwing: error)
        }
    }

    /// A finished download should never leave more than one library row for the
    /// same server item. This only reports — it changes nothing — so that if it
    /// ever does happen, there's a timestamped record tying it to the download
    /// rather than a reconstruction after the fact.
    private func warnIfDuplicated(_ audiobook: Audiobook, in context: ModelContext) {
        guard let sourceId = audiobook.sourceIdentifier, !sourceId.isEmpty else { return }

        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate<Audiobook> { $0.sourceIdentifier == sourceId }
        )

        guard let matches = try? context.fetch(descriptor), matches.count > 1 else { return }

        let ids = matches.map(\.id.uuidString).joined(separator: ", ")
        let withoutArtwork = matches.filter { $0.artworkData?.isEmpty ?? true }.count
        logger.warning(
            """
            DUPLICATE CANARY: \(matches.count) library rows share sourceIdentifier \
            \(sourceId) after downloading '\(audiobook.title)' \
            (\(withoutArtwork) without artwork) — ids: \(ids)
            """
        )
    }

    private func fetchAudiobook(id: UUID) -> Audiobook? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<Audiobook>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Pending Record Persistence

    /// A background transfer can outlive the process. Persisting the small
    /// bookkeeping record means a relaunch can still move the finished file into
    /// the cache and record its `CacheEntry`.
    private struct PersistedRecord: Codable {
        let audiobookId: UUID
        let destinationPath: String
        let expectedBytes: Int64
    }

    private static let pendingDefaultsKey = "audiobookshelf.pendingDownloads"

    private func persistPendingRecords() {
        let snapshot = records.withLock { $0 }
        let persisted = snapshot.values.map {
            PersistedRecord(
                audiobookId: $0.audiobookId,
                destinationPath: $0.destinationPath,
                expectedBytes: $0.expectedBytes
            )
        }

        if persisted.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingDefaultsKey)
        } else if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.pendingDefaultsKey)
        }
    }

    private func restorePendingRecords() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingDefaultsKey),
            let persisted = try? JSONDecoder().decode([PersistedRecord].self, from: data)
        else { return }

        records.withLock { state in
            for entry in persisted where state[entry.audiobookId.uuidString] == nil {
                state[entry.audiobookId.uuidString] = TaskRecord(
                    audiobookId: entry.audiobookId,
                    destinationPath: entry.destinationPath,
                    expectedBytes: entry.expectedBytes
                )
            }
        }

        logger.info("Restored \(persisted.count) pending Audiobookshelf download record(s)")
    }

    // MARK: - Storage Helpers

    /// watchOS has no `volumeAvailableCapacityForImportantUsage`, so use the
    /// file-system attributes available on both platforms. Mirrors the check in
    /// `CloudKitChunkedTransferManager.downloadAudiobook`.
    static func verifyFreeSpace(for fileSize: Int64, in directory: URL) throws {
        guard fileSize > 0 else { return }

        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(
                forPath: directory.path),
            let freeSize = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        else {
            return
        }

        // Leave headroom rather than filling the disk exactly.
        let required = Int64(Double(fileSize) * 1.1)
        if freeSize < required {
            throw AudiobookshelfDownloadError.insufficientStorage
        }
    }

    // Resume-data helpers are `nonisolated`: they only touch the file system and
    // are called from the session's delegate queue.

    nonisolated private static var resumeDataDirectory: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudiobookshelfResume")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    nonisolated static func resumeDataURL(for audiobookId: UUID) -> URL {
        resumeDataDirectory.appendingPathComponent("\(audiobookId.uuidString).resume")
    }

    nonisolated private static func storeResumeData(_ data: Data, for audiobookId: UUID) {
        try? data.write(to: resumeDataURL(for: audiobookId), options: .atomic)
    }

    nonisolated private static func discardResumeData(for audiobookId: UUID) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: audiobookId))
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let key = downloadTask.taskDescription else { return }

        // Sample under the lock so a burst of callbacks can't all pass the gate.
        // `isBaseline` marks the first sample of a transfer: a resumed download
        // reports its whole resumed offset in one go, and treating that as
        // bytes-since-last-sample would invent an enormous rate.
        let sample: (audiobookId: UUID, expectedBytes: Int64, isBaseline: Bool)? = records.withLock
        { state in
            guard var record = state[key] else { return nil }

            let now = Date()
            if let last = record.lastProgressUpdate,
                now.timeIntervalSince(last) < Self.progressSampleInterval
            {
                return nil
            }

            let isBaseline = record.lastProgressUpdate == nil
            record.lastProgressUpdate = now
            state[key] = record
            return (record.audiobookId, record.expectedBytes, isBaseline)
        }

        guard let sample else { return }

        // Servers don't always send Content-Length; fall back to the size we
        // already know from the library metadata.
        let expected =
            totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : sample.expectedBytes

        Task { @MainActor in
            guard var progress = activeDownloads[sample.audiobookId] else { return }

            if expected > 0 {
                progress.totalBytes = expected
            }

            if sample.isBaseline {
                // Establish the starting point without deriving a rate from it.
                let now = Date()
                progress.bytesTransferred = totalBytesWritten
                progress.startTime = now
                progress.lastUpdateTime = now
            } else {
                progress.updateProgress(completedChunks: 0, bytesTransferred: totalBytesWritten)
            }

            activeDownloads[sample.audiobookId] = progress
            TransferProgressCenter.shared.report(
                sample.audiobookId, fraction: progress.progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let key = downloadTask.taskDescription,
            let record = records.withLock({ $0[key] })
        else { return }

        // An error page would otherwise be written to disk as "the audiobook".
        if let http = downloadTask.response as? HTTPURLResponse,
            !(200..<300).contains(http.statusCode)
        {
            records.withLock { $0[key]?.failure = .server(statusCode: http.statusCode) }
            return
        }

        // A body that arrived short of what the server promised must not become
        // a "downloaded" book — playback would just stop where the bytes end.
        // Only checked on a fresh 200: a resumed transfer answers 206 whose
        // Content-Length covers the remaining range, not the whole file.
        if let http = downloadTask.response as? HTTPURLResponse,
            http.statusCode == 200,
            http.expectedContentLength > 0,
            let received = Self.fileSize(at: location),
            received < http.expectedContentLength
        {
            records.withLock {
                $0[key]?.failure = .truncated(
                    received: received, expected: http.expectedContentLength)
            }
            return
        }

        // The temporary file is deleted as soon as this method returns, so the
        // move has to happen here, on the delegate queue.
        let destination = URL(fileURLWithPath: record.destinationPath)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            records.withLock { $0[key]?.movedURL = destination }
        } catch {
            records.withLock { $0[key]?.failure = .fileMove(error.localizedDescription) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let key = task.taskDescription,
            let record = records.withLock({ $0[key] })
        else { return }

        let audiobookId = record.audiobookId

        if let error {
            let nsError = error as NSError

            // Both cancels and mid-flight failures can hand back resume data.
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Self.storeResumeData(resumeData, for: audiobookId)
            }

            let mapped: Error =
                nsError.code == NSURLErrorCancelled
                ? AudiobookshelfDownloadError.cancelled
                : AudiobookshelfError.from(error)

            Task { @MainActor in
                finish(audiobookId: audiobookId, result: .failure(mapped))
            }
            return
        }

        if let failure = record.failure {
            let mapped: Error =
                switch failure {
                case .server(let statusCode):
                    AudiobookshelfDownloadError.serverError(statusCode: statusCode)
                case .fileMove(let message):
                    AudiobookshelfDownloadError.fileMoveFailed(message)
                case .truncated(let received, let expected):
                    AudiobookshelfDownloadError.truncated(
                        received: received, expected: expected)
                }

            Task { @MainActor in
                finish(audiobookId: audiobookId, result: .failure(mapped))
            }
            return
        }

        guard let movedURL = record.movedURL else {
            Task { @MainActor in
                finish(
                    audiobookId: audiobookId,
                    result: .failure(AudiobookshelfError.invalidResponse))
            }
            return
        }

        Self.discardResumeData(for: audiobookId)
        Task { @MainActor in
            finish(audiobookId: audiobookId, result: .success(movedURL))
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            logger.info("Audiobookshelf background session finished all events")
            Self.backgroundEventsHandler?()
            Self.backgroundEventsHandler = nil
        }
    }
}
