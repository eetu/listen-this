//
//  CloudKitChunkedTransferManager.swift
//  Listen This
//
//  Manages chunked file transfers via CloudKit
//  Enables fast, reliable audiobook transfers to Apple Watch
//

import CloudKit
import Foundation
import OSLog
import Observation
import SwiftData

#if os(iOS)
    import UIKit
#elseif os(watchOS)
    import WatchKit
#endif

// MARK: - Concrete Implementation

@MainActor
@Observable
final class CloudKitChunkedTransferManager: NSObject, CloudKitTransferManager, URLSessionDelegate,
    URLSessionDownloadDelegate
{

    // MARK: - Configuration

    static let chunkSize = 100 * 1024 * 1024
    private let maxRetryCount = 3
    private let retryBaseDelay: UInt64 = 500_000_000

    private let container: CKContainer
    private let database: CKDatabase
    private let modelContext: ModelContext
    private let logger = AppLogger.cloudKit

    // MARK: - Background URLSession
    // Note: Background URLSession is configured but not currently used for chunk downloads
    // CKAsset.fileURL provides local file:// URLs which we read directly
    // Keeping the session for potential future use with remote CloudKit asset URLs

    private var backgroundSession: URLSession!

    // MARK: - Background Execution

    #if os(iOS)
        private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #elseif os(watchOS)
        private var extendedRuntimeSession: WKExtendedRuntimeSession?
    #endif

    // MARK: - Observable State

    var activeUploads: [UUID: ChunkTransferProgress] = [:]
    var activeDownloads: [UUID: ChunkTransferProgress] = [:]

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.container = CKContainer(identifier: "iCloud.com.anarkisti.Listen-This")
        self.database = container.privateCloudDatabase

        super.init()

        // Configure background URLSession for chunk downloads
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.anarkisti.ListenThis.cloudkit.chunks"
        )

        // Check user setting for cellular data usage (default: WiFi-only)
        let allowCellular = SettingsManager.shared.allowCellularForCloudKitTransfers
        config.allowsCellularAccess = allowCellular

        config.waitsForConnectivity = true  // Wait for connectivity if not available
        config.isDiscretionary = false  // Don't wait for optimal conditions
        config.sessionSendsLaunchEvents = true

        backgroundSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )

        logger.info("CloudKit background session configured with cellular access: \(allowCellular)")
    }

    // MARK: - Upload

    func uploadAudiobook(_ audiobook: Audiobook) async throws {
        beginBackgroundExecution()
        defer { endBackgroundExecution() }

        guard let fileURL = audiobook.validCacheFileURL else {
            throw ChunkTransferError.fileNotAvailable
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw ChunkTransferError.invalidFile
        }

        let chunkCount = Int(ceil(Double(fileSize) / Double(Self.chunkSize)))
        let audiobookId = audiobook.id

        let availability = await checkCloudKitChunks(for: audiobook)

        if case .fullyUploaded = availability {
            throw ChunkTransferError.alreadyUploaded
        }

        let manifest = try await createOrFetchManifest(
            audiobookId: audiobookId,
            title: audiobook.title,
            fileSize: fileSize,
            chunkCount: chunkCount
        )

        // Check which chunks already exist for resume capability (iPhone only)
        let existingChunks: Set<Int>
        do {
            existingChunks = try await fetchExistingChunkIndexes(
                audiobookId: audiobookId,
                expectedChunkCount: chunkCount
            )
        } catch {
            existingChunks = []
        }

        let chunksToUpload = Array(0..<chunkCount).filter { !existingChunks.contains($0) }
        let alreadyUploadedChunks = chunkCount - chunksToUpload.count
        let bytesAlreadyTransferred = Int64(alreadyUploadedChunks) * Int64(Self.chunkSize)

        activeUploads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: fileSize,
            totalChunks: chunkCount,
            completedChunks: alreadyUploadedChunks,
            bytesTransferred: min(bytesAlreadyTransferred, fileSize),
            isUploading: true
        )
        // Ensure the progress entry is never orphaned: clear it on any exit
        // (success or thrown error) so the UI doesn't show a frozen ring.
        defer { activeUploads.removeValue(forKey: audiobookId) }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        for index in chunksToUpload {
            let data = try readChunk(from: handle, chunkIndex: index, totalSize: fileSize)

            try await uploadChunkWithRetry(
                chunkData: data,
                chunkIndex: index,
                manifestRecordId: manifest.recordID,
                audiobookId: audiobookId
            )

            if var progress = activeUploads[audiobookId] {
                progress.updateProgress(
                    completedChunks: progress.completedChunks + 1,
                    bytesTransferred: progress.bytesTransferred + Int64(data.count)
                )
                activeUploads[audiobookId] = progress
            }
        }

        try await markManifestComplete(manifest)
    }

    func cancelTransfer(audiobookId: UUID) {
        activeUploads.removeValue(forKey: audiobookId)
        activeDownloads.removeValue(forKey: audiobookId)
    }

    // MARK: - Download

    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL {
        beginBackgroundExecution()
        defer { endBackgroundExecution() }

        let audiobookId = audiobook.id
        let manifest = try await fetchManifest(audiobookId: audiobookId)

        guard let path = audiobook.expectedCachePath else {
            throw ChunkTransferError.fileNotAvailable
        }

        let outputURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Fail early if there isn't room for the whole file rather than filling
        // the (limited) Watch disk and dying partway through. Uses
        // attributesOfFileSystem since volumeAvailableCapacity* is iOS-only.
        let containingDir = outputURL.deletingLastPathComponent()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: containingDir.path),
            let freeSize = (attrs[.systemFreeSize] as? NSNumber)?.int64Value,
            freeSize < manifest.fileSize
        {
            throw ChunkTransferError.insufficientStorage
        }

        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        activeDownloads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: manifest.fileSize,
            totalChunks: manifest.chunkCount,
            completedChunks: 0,
            isUploading: false
        )
        // Ensure the progress entry is never orphaned on a thrown error.
        defer {
            activeDownloads.removeValue(forKey: audiobookId)
            TransferProgressCenter.shared.finish(audiobookId)
        }

        // Track success so a thrown error doesn't leave a corrupt partial file.
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                try? handle.close()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        var written: Int64 = 0

        for index in 0..<manifest.chunkCount {
            let data = try await downloadChunkWithRetry(
                chunkIndex: index,
                manifestRecordId: manifest.recordId,
                audiobookId: audiobookId
            )

            try handle.write(contentsOf: data)
            written += Int64(data.count)

            if var progress = activeDownloads[audiobookId] {
                progress.updateProgress(
                    completedChunks: progress.completedChunks + 1,
                    bytesTransferred: written
                )
                activeDownloads[audiobookId] = progress
            }

            // Publish for library rows, which can't observe this manager: it is
            // created per use and is gone once its sheet is dismissed.
            TransferProgressCenter.shared.report(
                audiobookId, bytesTransferred: written, totalBytes: manifest.fileSize)
        }

        // Verify BEFORE declaring success. Reaching the end of the chunk loop
        // only means no chunk threw — a short read leaves a truncated file that
        // would otherwise be cached and marked "Downloaded", and playback would
        // simply stop wherever the bytes ran out.
        try? handle.synchronize()

        guard written == manifest.fileSize,
            verifyDownloadedFile(at: outputURL, expectedSize: manifest.fileSize)
        else {
            logger.error(
                "Download incomplete for '\(audiobook.title)': wrote \(written) of \(manifest.fileSize) bytes"
            )
            // completedSuccessfully stays false, so the defer removes the
            // partial file rather than leaving it to masquerade as cached.
            throw ChunkTransferError.incompleteDownload
        }

        // Verified complete, so don't let the cleanup defer delete it.
        completedSuccessfully = true

        persistCacheEntry(for: audiobook, at: outputURL)

        // Clean up chunks and manifest from iCloud now that the local file is
        // verified, so an interrupted or short write can't delete the only
        // cloud copy and lose the audiobook entirely.
        Task {
            do {
                try await deleteAudiobookFromCloud(audiobookId: audiobook.id)
            } catch {
                // Log error but don't fail the download since file is already saved
                logger.error("Failed to cleanup from iCloud: \(error.localizedDescription)")
            }
        }

        return outputURL
    }

    /// Verify a downloaded file exists and matches the manifest's size before we
    /// reclaim its iCloud copy.
    private func verifyDownloadedFile(at url: URL, expectedSize: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attrs[.size] as? NSNumber)?.int64Value
        else {
            return false
        }
        return size == expectedSize
    }

    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws {
        let audiobookId = audiobook.id

        // Fetch manifest
        let manifest = try await fetchManifest(audiobookId: audiobookId)

        // Delete all chunks
        var recordsToDelete: [CKRecord.ID] = []

        for chunkIndex in 0..<manifest.chunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId.uuidString)-chunk-\(chunkIndex)"
            )
            recordsToDelete.append(chunkRecordId)
        }

        // Delete manifest
        recordsToDelete.append(manifest.recordId)

        // Batch delete (CloudKit allows up to 400 operations)
        let batchSize = 400
        for startIndex in stride(from: 0, to: recordsToDelete.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, recordsToDelete.count)
            let batch = Array(recordsToDelete[startIndex..<endIndex])

            // Use modern async API to properly await deletion
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: batch
                )

                // Mark as long-lived for background execution
                let config = CKOperation.Configuration()
                config.isLongLived = true
                operation.configuration = config

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }
        }
    }

    /// Delete audiobook chunks by ID (for storage management views)
    func deleteAudiobookFromCloud(audiobookId: UUID) async throws {
        let manifest = try await fetchManifest(audiobookId: audiobookId)
        var recordsToDelete: [CKRecord.ID] = []

        for chunkIndex in 0..<manifest.chunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId.uuidString)-chunk-\(chunkIndex)"
            )
            recordsToDelete.append(chunkRecordId)
        }

        recordsToDelete.append(manifest.recordId)

        let batchSize = 400
        for startIndex in stride(from: 0, to: recordsToDelete.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, recordsToDelete.count)
            let batch = Array(recordsToDelete[startIndex..<endIndex])

            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: batch
                )

                // Mark as long-lived for background execution
                let config = CKOperation.Configuration()
                config.isLongLived = true
                operation.configuration = config

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }
        }
    }

    // MARK: - Retry Wrapper

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() } catch {
                // Don't retry quota exceeded errors - fail immediately with user-friendly message
                if let ckError = error as? CKError, ckError.code == .quotaExceeded {
                    throw ChunkTransferError.quotaExceeded
                }

                attempt += 1
                guard attempt <= maxRetryCount else {
                    // Convert CloudKit errors to user-friendly errors
                    throw ChunkTransferError.from(error)
                }
                try await Task.sleep(
                    nanoseconds: retryBaseDelay * UInt64(pow(2, Double(attempt - 1)))
                )
            }
        }
    }

    private func uploadChunkWithRetry(
        chunkData: Data,
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: UUID
    ) async throws {
        try await retry {
            try await uploadChunk(
                chunkData: chunkData,
                chunkIndex: chunkIndex,
                manifestRecordId: manifestRecordId,
                audiobookId: audiobookId
            )
        }
    }

    private func downloadChunkWithRetry(
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: UUID
    ) async throws -> Data {
        try await retry {
            try await downloadChunk(
                chunkIndex: chunkIndex,
                manifestRecordId: manifestRecordId,
                audiobookId: audiobookId
            )
        }
    }

    // MARK: - Background Execution

    private func beginBackgroundExecution() {
        #if os(iOS)
            backgroundTaskId = UIApplication.shared.beginBackgroundTask {
                Task { @MainActor in
                    self.endBackgroundExecution()
                }
            }
        #elseif os(watchOS)
            extendedRuntimeSession = WKExtendedRuntimeSession()
            extendedRuntimeSession?.start()
        #endif
    }

    private func endBackgroundExecution() {
        #if os(iOS)
            if backgroundTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskId)
                backgroundTaskId = .invalid
            }
        #elseif os(watchOS)
            extendedRuntimeSession?.invalidate()
            extendedRuntimeSession = nil
        #endif
    }

    // MARK: - Manifest

    func fetchManifest(audiobookId: UUID) async throws -> AudiobookManifest {
        let recordId = CKRecord.ID(recordName: "\(audiobookId.uuidString)-manifest")
        let record = try await database.record(for: recordId)

        guard
            let fileSize = record["fileSize"] as? Int64,
            let chunkCount = record["chunkCount"] as? Int,
            (record["isComplete"] as? Int64 ?? 0) == 1
        else {
            throw ChunkTransferError.incompleteUpload
        }

        return AudiobookManifest(
            recordId: recordId,
            audiobookId: audiobookId,
            fileSize: fileSize,
            chunkCount: chunkCount
        )
    }

    private func createOrFetchManifest(
        audiobookId: UUID,
        title: String,
        fileSize: Int64,
        chunkCount: Int
    ) async throws -> CKRecord {

        let recordId = CKRecord.ID(recordName: "\(audiobookId.uuidString)-manifest")

        if let record = try? await database.record(for: recordId) {
            return record
        }

        let record = CKRecord(recordType: "AudiobookManifest", recordID: recordId)
        record["audiobookId"] = audiobookId.uuidString
        record["title"] = title
        record["fileSize"] = fileSize
        record["chunkCount"] = chunkCount
        record["isComplete"] = Int64(0)
        record["uploadDate"] = Date()

        return try await database.save(record)
    }

    private func markManifestComplete(_ manifest: CKRecord) async throws {
        manifest["isComplete"] = Int64(1)
        manifest["completionDate"] = Date()
        _ = try await database.save(manifest)
    }

    // MARK: - Chunk Operations

    private func uploadChunk(
        chunkData: Data,
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: UUID
    ) async throws {

        let recordId = CKRecord.ID(
            recordName: "\(audiobookId.uuidString)-chunk-\(chunkIndex)"
        )

        let record = CKRecord(
            recordType: "AudiobookChunk",
            recordID: recordId
        )

        record["chunkIndex"] = chunkIndex
        record["manifest"] = CKRecord.Reference(
            recordID: manifestRecordId,
            action: .none
        )

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        try chunkData.write(to: tmp)
        record["data"] = CKAsset(fileURL: tmp)

        // Use long-lived operation for background execution
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(
                recordsToSave: [record],
                recordIDsToDelete: nil
            )

            // CRITICAL: Configure for long-lived background execution
            let config = CKOperation.Configuration()
            config.isLongLived = true
            operation.configuration = config
            operation.savePolicy = .changedKeys

            operation.modifyRecordsResultBlock = { result in
                Task { @MainActor in
                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tmp)

                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    private func downloadChunk(
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: UUID
    ) async throws -> Data {

        let recordId = CKRecord.ID(
            recordName: "\(audiobookId.uuidString)-chunk-\(chunkIndex)"
        )

        let record = try await database.record(for: recordId)

        guard let asset = record["data"] as? CKAsset,
            let url = asset.fileURL
        else {
            throw ChunkTransferError.readFailed
        }

        // CKAsset.fileURL is a local file:// URL pointing to CloudKit's cache
        // We can read it directly - no need for URLSession download
        logger.debug("Reading chunk \(chunkIndex) from CloudKit cache: \(url.path)")

        do {
            let data = try Data(contentsOf: url)
            logger.debug("Successfully read chunk \(chunkIndex) (\(data.count) bytes)")
            return data
        } catch {
            logger.error(
                "Failed to read chunk \(chunkIndex) from \(url.path): \(error.localizedDescription)"
            )
            throw ChunkTransferError.readFailed
        }
    }

    private func fetchExistingChunkIndexes(audiobookId: UUID, expectedChunkCount: Int) async throws
        -> Set<Int>
    {
        logger.debug("Fetching existing chunk indexes for: \(audiobookId)")
        logger.debug("Expected chunk count: \(expectedChunkCount)")

        var indexes = Set<Int>()

        // Check each chunk individually since batch fetch seems to hang on watchOS
        // This is slower but more reliable
        for chunkIndex in 0..<expectedChunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId.uuidString)-chunk-\(chunkIndex)")

            do {
                logger.debug("Checking chunk \(chunkIndex)...")
                _ = try await database.record(for: chunkRecordId)
                indexes.insert(chunkIndex)
                logger.debug("Chunk \(chunkIndex) exists")
            } catch {
                logger.debug("Chunk \(chunkIndex) not found: \(error.localizedDescription)")
            }
        }

        logger.info("Found \(indexes.count) of \(expectedChunkCount) chunks")
        return indexes
    }

    // MARK: - File IO

    private func readChunk(
        from handle: FileHandle,
        chunkIndex: Int,
        totalSize: Int64
    ) throws -> Data {

        let offset = Int64(chunkIndex) * Int64(Self.chunkSize)
        try handle.seek(toOffset: UInt64(offset))

        let remaining = totalSize - offset
        let count = min(Int64(Self.chunkSize), remaining)

        guard let data = try handle.read(upToCount: Int(count)) else {
            throw ChunkTransferError.readFailed
        }

        return data
    }

    /// Record a CacheEntry for the downloaded file so the book reads as cached
    /// (cacheEntry != nil) consistently with the direct-transfer path. Without
    /// this, a CloudKit/WiFi-downloaded book had its file on disk but no
    /// cacheEntry, so the library couldn't tell it was already downloaded.
    private func persistCacheEntry(for audiobook: Audiobook, at url: URL) {
        if audiobook.cacheEntry == nil {
            let entry = CacheEntry()
            entry.audiobook = audiobook
            audiobook.cacheEntry = entry
            modelContext.insert(entry)
        }
        audiobook.cacheEntry?.filePath = url.path
        audiobook.cacheEntry?.fileSize =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        audiobook.cacheEntry?.lastAccessedDate = Date()
        try? modelContext.save()
    }

    // MARK: - Chunk Availability Check

    /// Check if audiobook chunks exist in CloudKit and their upload status
    /// Used by both iPhone (before upload) and Watch (before download)
    func checkCloudKitChunks(for audiobook: Audiobook) async -> ChunkAvailability {
        do {
            let _ = try await fetchManifest(audiobookId: audiobook.id)

            // If the manifest exists and is marked complete, we trust that all chunks are uploaded
            // fetchManifest already validates isComplete == 1, so we don't need to check individual chunks
            // This avoids CloudKit query issues on watchOS
            return .fullyUploaded

        } catch {
            return .notUploaded
        }
    }

    // MARK: - URLSessionDownloadDelegate
    // Note: These delegate methods are kept for potential future use
    // Currently chunk downloads read directly from CKAsset.fileURL (local files)

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Currently unused - keeping for future compatibility
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Currently unused - keeping for future compatibility
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            logger.info("Background URLSession finished all events")

            #if os(iOS) && canImport(UIKit)
                // Call the completion handler stored in AppDelegate to let iOS know we're done
                // This is critical for iOS to properly handle background URL session events
                // Note: AppDelegate may not be available in test targets
                if let appDelegateClass = NSClassFromString("Listen_This.AppDelegate") as? NSObject.Type,
                   let handler = appDelegateClass.value(forKey: "backgroundSessionCompletionHandler") as? (() -> Void) {
                    DispatchQueue.main.async {
                        handler()
                    }
                    appDelegateClass.setValue(nil, forKey: "backgroundSessionCompletionHandler")
                    logger.info("Called background session completion handler")
                }
            #endif
        }
    }
}

/// Represents the availability status of audiobook chunks in CloudKit
/// Used to determine if chunks can be uploaded (iPhone) or downloaded (Watch)
enum ChunkAvailability: Equatable {
    case notUploaded  // No chunks in CloudKit - Watch cannot download
    case partiallyUploaded(existingChunks: Set<Int>)  // Some chunks exist - can resume upload
    case fullyUploaded  // All chunks in CloudKit - Watch can download
}

// MARK: - Supporting Types

struct AudiobookManifest {
    let recordId: CKRecord.ID
    let audiobookId: UUID
    let fileSize: Int64
    let chunkCount: Int
}

struct ChunkTransferProgress: Equatable {
    let audiobookId: UUID
    /// Mutable because a single-stream download only learns the real size from
    /// the response's Content-Length, after the transfer has started.
    var totalBytes: Int64
    let totalChunks: Int
    var completedChunks: Int
    var bytesTransferred: Int64 = 0
    let isUploading: Bool

    /// Single-stream transfers (an Audiobookshelf download is one HTTP response,
    /// not a chunk sequence) report progress in bytes. Chunked CloudKit
    /// transfers keep the default and are unaffected.
    var usesByteProgress: Bool = false


    // Speed tracking
    var startTime: Date = Date()
    var lastUpdateTime: Date = Date()
    /// Exponential moving average of recent throughput so the displayed speed
    /// reflects current conditions and recovers after a stall, rather than being
    /// dragged down forever by a lifetime average.
    var smoothedSpeedBytesPerSecond: Double = 0

    var progress: Double {
        if usesByteProgress {
            guard totalBytes > 0 else { return 0 }
            return min(1, Double(bytesTransferred) / Double(totalBytes))
        }
        guard totalChunks > 0 else { return 0 }
        return Double(completedChunks) / Double(totalChunks)
    }

    var progressPercentage: Int {
        Int(progress * 100)
    }

    var progressText: String {
        let transferred = ByteCountFormatter.string(
            fromByteCount: bytesTransferred,
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
        return "\(transferred) / \(total)"
    }

    var statusText: String {
        if usesByteProgress {
            return isUploading ? "Uploading" : "Downloading"
        }
        // Clamp so we never display "chunk N+1 of N" on the final update.
        let displayChunk = min(completedChunks + 1, totalChunks)
        if isUploading {
            return "Uploading chunk \(displayChunk) of \(totalChunks)"
        } else {
            return "Downloading chunk \(displayChunk) of \(totalChunks)"
        }
    }

    /// Current transfer speed in bytes per second, smoothed over recent activity.
    /// Falls back to the lifetime average only before the first windowed sample.
    var currentSpeedBytesPerSecond: Double {
        if smoothedSpeedBytesPerSecond > 0 { return smoothedSpeedBytesPerSecond }
        let elapsed = lastUpdateTime.timeIntervalSince(startTime)
        // The lifetime average needs a real window too. Early in a transfer
        // `elapsed` can be a fraction of a millisecond, and dividing by it
        // yields the same absurd gigabytes-per-second the smoothing guards
        // against. Report nothing until the number would mean something.
        guard elapsed >= Self.minimumSampleInterval else { return 0 }
        return Double(bytesTransferred) / elapsed
    }
    
    /// Formatted transfer speed string
    var speedText: String {
        let speed = currentSpeedBytesPerSecond
        guard speed > 0 else { return "" }
        let speedFormatted = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
        return "\(speedFormatted)/s"
    }
    
    /// Estimated time remaining in seconds
    var estimatedTimeRemaining: TimeInterval? {
        let speed = currentSpeedBytesPerSecond
        guard speed > 0 else { return nil }
        let remainingBytes = totalBytes - bytesTransferred
        return Double(remainingBytes) / speed
    }
    
    /// Formatted estimated time remaining
    var estimatedTimeRemainingText: String? {
        guard let remaining = estimatedTimeRemaining, remaining > 0, remaining.isFinite else { return nil }
        
        if remaining < 60 {
            return "< 1 min remaining"
        } else if remaining < 3600 {
            let minutes = Int(remaining / 60)
            return "\(minutes) min remaining"
        } else {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes > 0 {
                return "\(hours)h \(minutes)m remaining"
            } else {
                return "\(hours)h remaining"
            }
        }
    }
    
    /// Update progress and refresh timing. Computes an instantaneous rate from
    /// the delta since the last update and folds it into a moving average.
    /// Time constant of the speed average, in seconds.
    private static let speedTimeConstant: Double = 3

    /// Samples closer together than this can't produce a trustworthy rate —
    /// dividing by a near-zero interval is what yields absurd readings.
    private static let minimumSampleInterval: Double = 0.05

    mutating func updateProgress(completedChunks: Int, bytesTransferred: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdateTime)
        let deltaBytes = bytesTransferred - self.bytesTransferred

        if dt >= Self.minimumSampleInterval, deltaBytes > 0 {
            let instantaneous = Double(deltaBytes) / dt

            // Weight by how much time the sample covers rather than using a
            // fixed alpha. Sample spacing ranges from half a second (a byte
            // stream) to tens of seconds (a 100 MB chunk); a fixed weight is
            // either too jumpy for one or too sluggish for the other.
            let weight = 1 - exp(-dt / Self.speedTimeConstant)

            smoothedSpeedBytesPerSecond =
                smoothedSpeedBytesPerSecond > 0
                ? weight * instantaneous + (1 - weight) * smoothedSpeedBytesPerSecond
                : instantaneous
        }

        self.completedChunks = completedChunks
        self.bytesTransferred = bytesTransferred
        self.lastUpdateTime = now
    }
}

enum ChunkTransferError: LocalizedError {
    case fileNotAvailable
    case invalidFile
    case readFailed
    case writeFailed
    case chunkNotFound
    case incompleteUpload
    case incompleteDownload
    case networkError
    case quotaExceeded
    case insufficientStorage
    case cloudKitError(String)
    static let alreadyUploaded = ChunkTransferError.incompleteUpload

    var errorDescription: String? {
        switch self {
        case .fileNotAvailable:
            return "File is not available for transfer"
        case .invalidFile:
            return "File is invalid or corrupted"
        case .readFailed:
            return "Failed to read file data"
        case .writeFailed:
            return "Failed to write file data"
        case .chunkNotFound:
            return "Chunk data not found in CloudKit"
        case .incompleteUpload:
            return "Upload is incomplete, try again"
        case .incompleteDownload:
            return "The download finished short of the full audiobook and was discarded. Try again."
        case .networkError:
            return "Network error during transfer"
        case .quotaExceeded:
            return "iCloud storage is full. Free up space or use Direct Transfer instead."
        case .insufficientStorage:
            return "Not enough free space on this device to download the audiobook. Free up space and try again."
        case .cloudKitError(let message):
            return message
        }
    }

    /// Convert a CloudKit error to a user-friendly ChunkTransferError
    static func from(_ error: Error) -> ChunkTransferError {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .quotaExceeded:
                return .quotaExceeded
            case .networkFailure, .networkUnavailable:
                return .networkError
            default:
                return .cloudKitError(ckError.localizedDescription)
            }
        }
        return .cloudKitError(error.localizedDescription)
    }
}
