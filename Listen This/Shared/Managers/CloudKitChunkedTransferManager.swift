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

    private var backgroundSession: URLSession!

    // Track ongoing download tasks to update progress
    private var downloadTasks: [URLSessionDownloadTask: (audiobookId: UUID, chunkIndex: Int)] = [:]
    private var downloadedChunkData: [String: Data] = [:]  // Key: "audiobookId-chunkIndex"
    private var downloadContinuations: [String: CheckedContinuation<Data, Error>] = [:]

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

            activeUploads[audiobookId]?.completedChunks += 1
            activeUploads[audiobookId]?.bytesTransferred += Int64(data.count)
        }

        try await markManifestComplete(manifest)
        activeUploads.removeValue(forKey: audiobookId)
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

        var written: Int64 = 0

        for index in 0..<manifest.chunkCount {
            let data = try await downloadChunkWithRetry(
                chunkIndex: index,
                manifestRecordId: manifest.recordId,
                audiobookId: audiobookId
            )

            try handle.write(contentsOf: data)
            written += Int64(data.count)

            activeDownloads[audiobookId]?.completedChunks += 1
            activeDownloads[audiobookId]?.bytesTransferred = written
        }

        persistCacheEntry()
        activeDownloads.removeValue(forKey: audiobookId)

        // Clean up chunks and manifest from iCloud after successful download
        // This frees up iCloud storage since the file is now on the Watch
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
                attempt += 1
                guard attempt <= maxRetryCount else { throw error }
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

        // Use background URLSession for chunk download
        let key = "\(audiobookId.uuidString)-\(chunkIndex)"

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                // Store continuation for when download completes
                self.downloadContinuations[key] = continuation

                // Create background download task
                let downloadTask = self.backgroundSession.downloadTask(with: url)
                self.downloadTasks[downloadTask] = (audiobookId, chunkIndex)
                downloadTask.resume()

                self.logger.debug(
                    "Started background download for chunk \(chunkIndex) of \(audiobookId)")
            }
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

    private func persistCacheEntry() {
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

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            guard let taskInfo = downloadTasks[downloadTask] else {
                logger.error("Received download completion for unknown task")
                return
            }

            let key = "\(taskInfo.audiobookId.uuidString)-\(taskInfo.chunkIndex)"

            do {
                // Read the downloaded chunk data
                let data = try Data(contentsOf: location)

                // Resume the continuation with the data
                if let continuation = downloadContinuations.removeValue(forKey: key) {
                    continuation.resume(returning: data)
                } else {
                    logger.warning("No continuation found for chunk \(taskInfo.chunkIndex)")
                }

                downloadTasks.removeValue(forKey: downloadTask)
                logger.debug("Completed background download for chunk \(taskInfo.chunkIndex)")

            } catch {
                logger.error("Failed to read downloaded chunk: \(error.localizedDescription)")
                if let continuation = downloadContinuations.removeValue(forKey: key) {
                    continuation.resume(throwing: error)
                }
                downloadTasks.removeValue(forKey: downloadTask)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            guard let error = error else { return }

            if let downloadTask = task as? URLSessionDownloadTask,
                let taskInfo = downloadTasks[downloadTask]
            {
                let key = "\(taskInfo.audiobookId.uuidString)-\(taskInfo.chunkIndex)"

                logger.error(
                    "Download task failed for chunk \(taskInfo.chunkIndex): \(error.localizedDescription)"
                )

                if let continuation = downloadContinuations.removeValue(forKey: key) {
                    continuation.resume(throwing: error)
                }
                downloadTasks.removeValue(forKey: downloadTask)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            logger.info("Background URLSession finished all events")

            #if os(iOS)
                // Call the completion handler stored in AppDelegate to let iOS know we're done
                // This is critical for iOS to properly handle background URL session events
                if let handler = AppDelegate.backgroundSessionCompletionHandler {
                    DispatchQueue.main.async {
                        handler()
                    }
                    AppDelegate.backgroundSessionCompletionHandler = nil
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
    let totalBytes: Int64
    let totalChunks: Int
    var completedChunks: Int
    var bytesTransferred: Int64 = 0
    let isUploading: Bool

    var progress: Double {
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
        if isUploading {
            return "Uploading chunk \(completedChunks + 1) of \(totalChunks)"
        } else {
            return "Downloading chunk \(completedChunks + 1) of \(totalChunks)"
        }
    }
}

enum ChunkTransferError: LocalizedError {
    case fileNotAvailable
    case invalidFile
    case readFailed
    case writeFailed
    case chunkNotFound
    case incompleteUpload
    case networkError
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
        case .networkError:
            return "Network error during transfer"
        }
    }
}
