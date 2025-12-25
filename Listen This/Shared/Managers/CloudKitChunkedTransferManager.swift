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

// MARK: - Public Protocol (View-Facing)

@MainActor
protocol CloudKitTransferManager: AnyObject {
    var activeUploads: [String: ChunkTransferProgress] { get }
    var activeDownloads: [String: ChunkTransferProgress] { get }
    
    func uploadAudiobook(_ audiobook: Audiobook) async throws
    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL
    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws
    func deleteAudiobookFromCloud(audiobookId: String) async throws
    func checkCloudKitChunks(for audiobook: Audiobook) async -> ChunkAvailability
    func cancelTransfer(audiobookId: String)
}

// MARK: - Concrete Implementation

@MainActor
@Observable
final class CloudKitChunkedTransferManager: CloudKitTransferManager {

    // MARK: - Configuration

    static let chunkSize = 100 * 1024 * 1024
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

        // Clean up chunks and manifest from iCloud after successful download
        // This frees up iCloud storage since the file is now on the Watch
        Task {
            do {
                try await deleteAudiobookFromCloud(audiobook)
            } catch {
                // Log error but don't fail the download since file is already saved
                print("[CloudKitChunkedTransferManager] Failed to cleanup from iCloud: \(error)")
            }
        }

        return outputURL
    }

    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws {
        let audiobookId = audiobook.id.uuidString

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

    /// Delete audiobook chunks by ID (for storage management views)
    func deleteAudiobookFromCloud(audiobookId: String) async throws {
        let manifest = try await fetchManifest(audiobookId: audiobookId)
        var recordsToDelete: [CKRecord.ID] = []

        for chunkIndex in 0..<manifest.chunkCount {
            let chunkRecordId = CKRecord.ID(
                recordName: "\(audiobookId)-chunk-\(chunkIndex)"
            )
            recordsToDelete.append(chunkRecordId)
        }

        recordsToDelete.append(manifest.recordId)

        let batchSize = 400
        for startIndex in stride(from: 0, to: recordsToDelete.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, recordsToDelete.count)
            let batch = Array(recordsToDelete[startIndex..<endIndex])

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

    func fetchManifest(audiobookId: String) async throws -> AudiobookManifest {
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

    private func fetchExistingChunkIndexes(audiobookId: String, expectedChunkCount: Int) async throws -> Set<Int> {
        print("[CloudKitChunkedTransferManager] Fetching existing chunk indexes for: \(audiobookId)")
        print("[CloudKitChunkedTransferManager] Expected chunk count: \(expectedChunkCount)")

        var indexes = Set<Int>()

        // Check each chunk individually since batch fetch seems to hang on watchOS
        // This is slower but more reliable
        for chunkIndex in 0..<expectedChunkCount {
            let chunkRecordId = CKRecord.ID(recordName: "\(audiobookId)-chunk-\(chunkIndex)")

            do {
                print("[CloudKitChunkedTransferManager] Checking chunk \(chunkIndex)...")
                _ = try await database.record(for: chunkRecordId)
                indexes.insert(chunkIndex)
                print("[CloudKitChunkedTransferManager] ✓ Chunk \(chunkIndex) exists")
            } catch {
                print("[CloudKitChunkedTransferManager] ✗ Chunk \(chunkIndex) not found: \(error.localizedDescription)")
            }
        }

        print("[CloudKitChunkedTransferManager] Found \(indexes.count) of \(expectedChunkCount) chunks")
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
            let manifest = try await fetchManifest(audiobookId: audiobook.id.uuidString)

            // If the manifest exists and is marked complete, we trust that all chunks are uploaded
            // fetchManifest already validates isComplete == 1, so we don't need to check individual chunks
            // This avoids CloudKit query issues on watchOS
            return .fullyUploaded

        } catch {
            return .notUploaded
        }
    }
}

/// Represents the availability status of audiobook chunks in CloudKit
/// Used to determine if chunks can be uploaded (iPhone) or downloaded (Watch)
enum ChunkAvailability: Equatable {
    case notUploaded           // No chunks in CloudKit - Watch cannot download
    case partiallyUploaded(existingChunks: Set<Int>)  // Some chunks exist - can resume upload
    case fullyUploaded         // All chunks in CloudKit - Watch can download
}

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
// MARK: - Mock Implementation (Previews & Testing)

@MainActor
@Observable
final class MockCloudKitTransferManager: CloudKitTransferManager {
    var activeUploads: [String: ChunkTransferProgress] = [:]
    var activeDownloads: [String: ChunkTransferProgress] = [:]
    
    private var uploadedBooks: Set<String> = []
    
    func uploadAudiobook(_ audiobook: Audiobook) async throws {
        let audiobookId = audiobook.id.uuidString
        
        // Simulate upload
        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 50_000_000,
            totalChunks: 10,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: true
        )
        activeUploads[audiobookId] = progress
        
        // Simulate chunk uploads
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if var currentProgress = activeUploads[audiobookId] {
                currentProgress.completedChunks = i
                currentProgress.bytesTransferred = Int64(i) * 5_000_000
                activeUploads[audiobookId] = currentProgress
            }
        }
        
        activeUploads.removeValue(forKey: audiobookId)
        uploadedBooks.insert(audiobookId)
    }
    
    func downloadAudiobook(_ audiobook: Audiobook) async throws -> URL {
        let audiobookId = audiobook.id.uuidString
        
        // Check if uploaded
        guard uploadedBooks.contains(audiobookId) else {
            throw ChunkTransferError.fileNotAvailable
        }
        
        // Simulate download
        let progress = ChunkTransferProgress(
            audiobookId: audiobookId,
            totalBytes: 50_000_000,
            totalChunks: 10,
            completedChunks: 0,
            bytesTransferred: 0,
            isUploading: false
        )
        activeDownloads[audiobookId] = progress
        
        // Simulate chunk downloads
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if var currentProgress = activeDownloads[audiobookId] {
                currentProgress.completedChunks = i
                currentProgress.bytesTransferred = Int64(i) * 5_000_000
                activeDownloads[audiobookId] = currentProgress
            }
        }
        
        activeDownloads.removeValue(forKey: audiobookId)
        
        // Return mock URL
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(audiobookId).m4b")
    }
    
    func deleteAudiobookFromCloud(_ audiobook: Audiobook) async throws {
        uploadedBooks.remove(audiobook.id.uuidString)
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func deleteAudiobookFromCloud(audiobookId: String) async throws {
        uploadedBooks.remove(audiobookId)
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    
    func checkCloudKitChunks(for audiobook: Audiobook) async -> ChunkAvailability {
        let audiobookId = audiobook.id.uuidString

        if uploadedBooks.contains(audiobookId) {
            return .fullyUploaded
        }

        return .notUploaded
    }
    
    func cancelTransfer(audiobookId: String) {
        activeUploads.removeValue(forKey: audiobookId)
        activeDownloads.removeValue(forKey: audiobookId)
    }
}


