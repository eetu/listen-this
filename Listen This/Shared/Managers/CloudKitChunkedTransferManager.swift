//
//  CloudKitChunkedTransferManager.swift
//  Listen This
//
//  Manages chunked file transfers via CloudKit
//  Enables fast, reliable audiobook transfers to Apple Watch
//

import Foundation
import CloudKit
import SwiftData
import Observation

#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

@MainActor
@Observable
final class CloudKitChunkedTransferManager {

    // MARK: - Configuration

    static let chunkSize = 200 * 1024 * 1024
    private let maxRetryCount = 3
    private let retryBaseDelay: UInt64 = 500_000_000

    private let container: CKContainer
    private let database: CKDatabase
    private let modelContext: ModelContext

    // MARK: - Background Execution

    #if os(iOS)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #elseif os(watchOS)
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    #endif

    // MARK: - Observable State

    var activeUploads: [String: ChunkTransferProgress] = [:]
    var activeDownloads: [String: ChunkTransferProgress] = [:]

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.container = CKContainer(identifier: "iCloud.com.anarkisti.Listen-This")
        self.database = container.privateCloudDatabase
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
        let audiobookId = audiobook.id.uuidString

        let availability = await uploadAvailability(for: audiobook)

        if case .fullyUploaded = availability {
            throw ChunkTransferError.alreadyUploaded
        }

        let chunksToUpload: [Int]
        if case .partiallyUploaded(let existing) = availability {
            chunksToUpload = Array(0..<chunkCount).filter { !existing.contains($0) }
        } else {
            chunksToUpload = Array(0..<chunkCount)
        }

        let manifest = try await createOrFetchManifest(
            audiobookId: audiobookId,
            title: audiobook.title,
            fileSize: fileSize,
            chunkCount: chunkCount
        )

        activeUploads[audiobookId] = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: fileSize,
            totalChunks: chunkCount,
            completedChunks: chunkCount - chunksToUpload.count,
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
        }

        try await markManifestComplete(manifest)
        activeUploads.removeValue(forKey: audiobookId)
    }

    func cancelTransfer(audiobookId: String) {
        activeUploads.removeValue(forKey: audiobookId)
        activeDownloads.removeValue(forKey: audiobookId)
    }
    
    // MARK: - Download

    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL {
        beginBackgroundExecution()
        defer { endBackgroundExecution() }

        let audiobookId = audiobook.id.uuidString
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

        return outputURL
    }
    
    func deleteAudiobookFromCloud(audiobookId: String) async throws {
        // Fetch manifest
        let manifest = try await fetchManifest(audiobookId: audiobookId)
        
        // Delete all chunks
        var recordsToDelete: [CKRecord.ID] = []
        
        for chunkIndex in 0..<manifest.chunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId)-chunk-\(chunkIndex)"
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: batch
                )
                
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
            do { return try await operation() }
            catch {
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
        audiobookId: String
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
        audiobookId: String
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
            self.endBackgroundExecution()
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

    private func createOrFetchManifest(
        audiobookId: String,
        title: String,
        fileSize: Int64,
        chunkCount: Int
    ) async throws -> CKRecord {

        let recordId = CKRecord.ID(recordName: "\(audiobookId)-manifest")

        if let record = try? await database.record(for: recordId) {
            return record
        }

        let record = CKRecord(recordType: "AudiobookManifest", recordID: recordId)
        record["audiobookId"] = audiobookId
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

    private func fetchManifest(audiobookId: String) async throws -> AudiobookManifest {
        let recordId = CKRecord.ID(recordName: "\(audiobookId)-manifest")
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

    // MARK: - Chunk Operations

    private func uploadChunk(
        chunkData: Data,
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: String
    ) async throws {

        let recordId = CKRecord.ID(
            recordName: "\(audiobookId)-chunk-\(chunkIndex)"
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

        _ = try await database.save(record)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func downloadChunk(
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: String
    ) async throws -> Data {

        let recordId = CKRecord.ID(
            recordName: "\(audiobookId)-chunk-\(chunkIndex)"
        )

        let record = try await database.record(for: recordId)

        guard let asset = record["data"] as? CKAsset,
              let url = asset.fileURL
        else {
            throw ChunkTransferError.readFailed
        }

        return try Data(contentsOf: url)
    }

    private func fetchExistingChunkIndexes(audiobookId: String) async throws -> Set<Int> {
        let predicate = NSPredicate(
            format: "recordID BEGINSWITH %@",
            "\(audiobookId)-chunk-"
        )

        let query = CKQuery(recordType: "AudiobookChunk", predicate: predicate)
        var indexes = Set<Int>()

        let (results, _) = try await database.records(matching: query)

        for (_, result) in results {
            if case .success(let record) = result,
               let index = record["chunkIndex"] as? Int {
                indexes.insert(index)
            }
        }

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

    // MARK: - Upload Availability

    func uploadAvailability(for audiobook: Audiobook) async -> UploadAvailability {
        do {
            let manifest = try await fetchManifest(audiobookId: audiobook.id.uuidString)
            let chunks = try await fetchExistingChunkIndexes(
                audiobookId: audiobook.id.uuidString
            )

            return chunks.count == manifest.chunkCount
                ? .fullyUploaded
                : .partiallyUploaded(existingChunks: chunks)
        } catch {
            return .notUploaded
        }
    }
}

enum UploadAvailability {
    case notUploaded
    case partiallyUploaded(existingChunks: Set<Int>)
    case fullyUploaded
}
/*
import Foundation
import CloudKit
import SwiftData

/// Manages chunked file uploads and downloads via CloudKit
@MainActor
@Observable
final class CloudKitChunkedTransferManager {
    
    // MARK: - Configuration
    
    /// Size of each chunk (200MB leaves headroom under CloudKit's 250MB limit)
    static let chunkSize = 200 * 1024 * 1024 // 200 MB
    
    /// CloudKit container
    private let container: CKContainer
    private let database: CKDatabase
    
    /// Model context for tracking
    private let modelContext: ModelContext
    
    // MARK: - Observable State
    
    /// Active uploads: audiobookId -> progress
    var activeUploads: [String: ChunkTransferProgress] = [:]
    
    /// Active downloads: audiobookId -> progress
    var activeDownloads: [String: ChunkTransferProgress] = [:]
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.container = CKContainer(identifier: "iCloud.com.anarkisti.Listen-This")
        self.database = container.privateCloudDatabase
    }
    
    // MARK: - Upload (iPhone)
    
    /// Upload an audiobook file in chunks to CloudKit
    func uploadAudiobook(_ audiobook: Audiobook) async throws {
        guard let fileURL = audiobook.validCacheFileURL else {
            throw ChunkTransferError.fileNotAvailable
        }
        
        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw ChunkTransferError.invalidFile
        }
        
        // Calculate number of chunks
        let chunkCount = Int(ceil(Double(fileSize) / Double(Self.chunkSize)))
        
        // Initialize progress
        let audiobookId = audiobook.id.uuidString
        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: fileSize,
            totalChunks: chunkCount,
            completedChunks: 0,
            isUploading: true
        )
        activeUploads[audiobookId] = progress
        
        // Create manifest record
        let manifestRecord = try await createManifestRecord(
            audiobookId: audiobookId,
            title: audiobook.title,
            fileSize: fileSize,
            chunkCount: chunkCount
        )
        
        // Upload chunks
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        
        for chunkIndex in 0..<chunkCount {
            // Read chunk data
            let chunkData = try readChunk(
                from: fileHandle,
                chunkIndex: chunkIndex,
                totalSize: fileSize
            )
            
            // Upload chunk
            try await uploadChunk(
                chunkData: chunkData,
                chunkIndex: chunkIndex,
                manifestRecordId: manifestRecord.recordID,
                audiobookId: audiobookId
            )
            
            // Update progress
            if var currentProgress = activeUploads[audiobookId] {
                currentProgress.completedChunks += 1
                activeUploads[audiobookId] = currentProgress
            }
        }
        
        // Mark manifest as complete
        try await markManifestComplete(manifestRecord)
        
        // Remove from active uploads
        activeUploads.removeValue(forKey: audiobookId)
    }
    
    // MARK: - Download (Watch)
    
    /// Download an audiobook from CloudKit chunks and reconstruct
    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL {
        let audiobookId = audiobook.id.uuidString
        
        // Fetch manifest
        let manifest = try await fetchManifest(audiobookId: audiobookId)
        
        // Initialize progress
        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: manifest.fileSize,
            totalChunks: manifest.chunkCount,
            completedChunks: 0,
            isUploading: false
        )
        activeDownloads[audiobookId] = progress
        
        // Create output file
        guard let expectedPath = audiobook.expectedCachePath else {
            throw ChunkTransferError.fileNotAvailable
        }
        let outputURL = URL(fileURLWithPath: expectedPath)
        
        let directoryURL = outputURL.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        FileManager.default.createFile(atPath: expectedPath, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: outputURL)
        
        // Download and write chunks sequentially
        var totalBytesWritten: Int64 = 0
        for chunkIndex in 0..<manifest.chunkCount {
            let chunkData = try await downloadChunk(
                chunkIndex: chunkIndex,
                manifestRecordId: manifest.recordId,
                audiobookId: audiobookId
            )
            
            // Write chunk to file
            try fileHandle.write(contentsOf: chunkData)
            totalBytesWritten += Int64(chunkData.count)
            
            // Update progress
            if var currentProgress = activeDownloads[audiobookId] {
                currentProgress.completedChunks += 1
                currentProgress.bytesTransferred = totalBytesWritten
                activeDownloads[audiobookId] = currentProgress
            }
        }
        
        // Close the file handle explicitly before creating cache entry
        try fileHandle.close()
        
        // Create or update cache entry for the audiobook
        if audiobook.cacheEntry == nil {
            let cacheEntry = CacheEntry(
                filePath: expectedPath,
                fileSize: totalBytesWritten,
                downloadedDate: Date()
            )
            cacheEntry.audiobook = audiobook
            audiobook.cacheEntry = cacheEntry
            modelContext.insert(cacheEntry)
        } else {
            // Update existing cache entry
            audiobook.cacheEntry?.filePath = expectedPath
            audiobook.cacheEntry?.fileSize = totalBytesWritten
            audiobook.cacheEntry?.downloadedDate = Date()
            audiobook.cacheEntry?.lastAccessedDate = Date()
        }
        
        // Save the model context to persist cache entry
        try modelContext.save()
        
        // Remove from active downloads
        activeDownloads.removeValue(forKey: audiobookId)
        
        return outputURL
    }
    
    /// Check if audiobook is available in CloudKit
    func isAudiobookAvailableInCloud(audiobookId: String) async -> Bool {
        do {
            _ = try await fetchManifest(audiobookId: audiobookId)
            return true
        } catch {
            return false
        }
    }
    
    /// Cancel an active upload or download
    func cancelTransfer(audiobookId: String) {
        activeUploads.removeValue(forKey: audiobookId)
        activeDownloads.removeValue(forKey: audiobookId)
    }
    
    // MARK: - Cleanup
    
    /// Delete audiobook chunks from CloudKit
    func deleteAudiobookFromCloud(audiobookId: String) async throws {
        // Fetch manifest
        let manifest = try await fetchManifest(audiobookId: audiobookId)
        
        // Delete all chunks
        var recordsToDelete: [CKRecord.ID] = []
        
        for chunkIndex in 0..<manifest.chunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId)-chunk-\(chunkIndex)"
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(
                    recordsToSave: nil,
                    recordIDsToDelete: batch
                )
                
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
    
    // MARK: - Private Helpers - Manifest
    
    private func createManifestRecord(
        audiobookId: String,
        title: String,
        fileSize: Int64,
        chunkCount: Int
    ) async throws -> CKRecord {
        let recordId = CKRecord.ID(recordName: "\(audiobookId)-manifest")
        let record = CKRecord(recordType: "AudiobookManifest", recordID: recordId)
        
        record["audiobookId"] = audiobookId
        record["title"] = title
        record["fileSize"] = fileSize
        record["chunkCount"] = chunkCount
        record["isComplete"] = Int64(0) // Store as Int64: 0 = false, 1 = true
        record["uploadDate"] = Date()
        
        return try await database.save(record)
    }
    
    private func markManifestComplete(_ manifest: CKRecord) async throws {
        manifest["isComplete"] = Int64(1) // Store as Int64: 1 = true
        manifest["completionDate"] = Date()
        _ = try await database.save(manifest)
    }
    
    private func fetchManifest(audiobookId: String) async throws -> AudiobookManifest {
        let recordId = CKRecord.ID(recordName: "\(audiobookId)-manifest")
        let record = try await database.record(for: recordId)
        
        guard let fileSize = record["fileSize"] as? Int64,
              let chunkCount = record["chunkCount"] as? Int else {
            throw ChunkTransferError.incompleteUpload
        }
        
        // Check isComplete - it's stored as Int64, not Bool
        let isCompleteValue = record["isComplete"] as? Int64 ?? 0
        let isComplete = isCompleteValue == 1
        
        guard isComplete else {
            throw ChunkTransferError.incompleteUpload
        }
        
        return AudiobookManifest(
            recordId: recordId,
            audiobookId: audiobookId,
            fileSize: fileSize,
            chunkCount: chunkCount
        )
    }
    
    // MARK: - Private Helpers - Chunks
    
    private func readChunk(
        from fileHandle: FileHandle,
        chunkIndex: Int,
        totalSize: Int64
    ) throws -> Data {
        let offset = Int64(chunkIndex) * Int64(Self.chunkSize)
        try fileHandle.seek(toOffset: UInt64(offset))
        
        let remainingBytes = totalSize - offset
        let bytesToRead = min(Int64(Self.chunkSize), remainingBytes)
        
        guard let data = try fileHandle.read(upToCount: Int(bytesToRead)) else {
            throw ChunkTransferError.readFailed
        }
        
        return data
    }
    
    private func uploadChunk(
        chunkData: Data,
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: String
    ) async throws {
        let recordId = CKRecord.ID(recordName: "\(audiobookId)-chunk-\(chunkIndex)")
        let record = CKRecord(recordType: "AudiobookChunk", recordID: recordId)
        
        // Create temporary file for the chunk (CloudKit requires file URLs for assets)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(audiobookId)-chunk-\(chunkIndex).tmp")
        try chunkData.write(to: tempURL)
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let asset = CKAsset(fileURL: tempURL)
        record["chunkData"] = asset
        record["chunkIndex"] = chunkIndex
        record["manifestId"] = CKRecord.Reference(recordID: manifestRecordId, action: .deleteSelf)
        
        _ = try await database.save(record)
    }
    
    private func downloadChunk(
        chunkIndex: Int,
        manifestRecordId: CKRecord.ID,
        audiobookId: String
    ) async throws -> Data {
        let recordId = CKRecord.ID(recordName: "\(audiobookId)-chunk-\(chunkIndex)")
        let record = try await database.record(for: recordId)
        
        guard let asset = record["chunkData"] as? CKAsset,
              let fileURL = asset.fileURL else {
            throw ChunkTransferError.chunkNotFound
        }
        
        return try Data(contentsOf: fileURL)
    }
}

*/
// MARK: - Supporting Types

struct AudiobookManifest {
    let recordId: CKRecord.ID
    let audiobookId: String
    let fileSize: Int64
    let chunkCount: Int
}

struct ChunkTransferProgress: Equatable {
    let audiobookId: String
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
