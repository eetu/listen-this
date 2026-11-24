//
//  CloudKitStorageView.swift
//  Listen This
//
//  Manage CloudKit storage and uploaded audiobooks
//

import CloudKit
import OSLog
import SwiftData
import SwiftUI

struct CloudKitStorageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var audiobooks: [Audiobook]

    @State private var transferManager: CloudKitChunkedTransferManager?
    @State private var uploadedAudiobooks: [UploadedAudiobook] = []
    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var totalStorageUsed: Int64 = 0
    @State private var confirmingClearAll = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Storage Used")
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: totalStorageUsed, countStyle: .file)
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(
                    "Space in your iCloud storage taken by books sent to the Watch via iCloud."
                )
            }

            Section {
                if uploadedAudiobooks.isEmpty && !isLoading {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing waiting")
                            .font(.subheadline)
                        Text(
                            "Books sent via iCloud wait here until your Watch downloads them, then they're removed. To send one, swipe right on it in the library."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(uploadedAudiobooks) { uploaded in
                        UploadedAudiobookRow(uploaded: uploaded) {
                            Task {
                                await deleteFromCloud(uploaded.audiobookId)
                            }
                        }
                    }
                }
            } header: {
                Text("Waiting for the Watch")
            } footer: {
                if !uploadedAudiobooks.isEmpty {
                    Text(
                        "Deleting one frees its space. A book your Watch hasn't downloaded yet then has to be sent again."
                    )
                }
            }

            Section {
                Button("Remove All", role: .destructive) {
                    confirmingClearAll = true
                }
                .disabled(isLoading || uploadedAudiobooks.isEmpty)
            }
        }
        .refreshable {
            await loadStorageInfo()
        }
        .navigationTitle("iCloud Transfer Storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove All Uploads?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                Task { await clearAllData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Deletes \(uploadedAudiobooks.count) uploaded \(uploadedAudiobooks.count == 1 ? "book" : "books") (\(ByteCountFormatter.string(fromByteCount: totalStorageUsed, countStyle: .file))) from iCloud. Books already on your Watch stay there; the rest have to be sent again."
            )
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .task {
            transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
            await loadStorageInfo()
        }
    }

    // MARK: - Actions

    private func loadStorageInfo() async {
        isLoading = true

        do {
            // Query CloudKit for all manifest records
            let container = CKContainer(identifier: "iCloud.com.anarkisti.Listen-This")
            let database = container.privateCloudDatabase

            // Create query filtering by isComplete field (must be queryable in CloudKit schema)
            // Use isComplete == 1 because we store it as Int64 (0 = false, 1 = true)
            let query = CKQuery(
                recordType: "AudiobookManifest",
                predicate: NSPredicate(format: "isComplete == %@", NSNumber(value: 1))
            )

            // Sort by upload date (newest first)
            query.sortDescriptors = [NSSortDescriptor(key: "uploadDate", ascending: false)]

            // Use the correct async API signature
            let (matchResults, _) = try await database.records(
                matching: query,
                inZoneWith: nil,
                desiredKeys: ["audiobookId", "title", "fileSize", "uploadDate", "isComplete"],
                resultsLimit: 100
            )

            var uploads: [UploadedAudiobook] = []
            var totalSize: Int64 = 0

            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    // Extract values - query already filtered for isComplete == 1
                    // Note: audiobookId is stored as String in CloudKit, convert to UUID
                    if let audiobookIdString = record["audiobookId"] as? String,
                        let audiobookId = UUID(uuidString: audiobookIdString),
                        let title = record["title"] as? String,
                        let fileSize = record["fileSize"] as? Int64,
                        let uploadDate = record["uploadDate"] as? Date
                    {

                        uploads.append(
                            UploadedAudiobook(
                                audiobookId: audiobookId,
                                title: title,
                                fileSize: fileSize,
                                uploadDate: uploadDate
                            ))

                        totalSize += fileSize
                    } else {
                        AppLogger.cloudKit.warning(
                            "Failed to parse record fields - audiobookId: \(record["audiobookId"] as? String ?? "nil"), title: \(record["title"] as? String ?? "nil")"
                        )
                    }
                case .failure(let error):
                    AppLogger.cloudKit.error("Failed to load record: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                // Already sorted by CloudKit query (newest first)
                uploadedAudiobooks = uploads
                totalStorageUsed = totalSize
                isLoading = false

                AppLogger.cloudKit.info("Loaded \(uploads.count) audiobooks from CloudKit")
                AppLogger.cloudKit.debug(
                    "Total storage used: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))"
                )
            }

        } catch {
            await MainActor.run {
                errorMessage = "Failed to load storage info: \(error.localizedDescription)"
                showingError = true
                isLoading = false

                AppLogger.cloudKit.error("CloudKit query error: \(error.localizedDescription)")
            }
        }
    }

    private func deleteFromCloud(_ audiobookId: UUID) async {
        guard let manager = transferManager else { return }

        do {
            // Delete chunks and manifest from CloudKit
            try await manager.deleteAudiobookFromCloud(audiobookId: audiobookId)

            await MainActor.run {
                uploadedAudiobooks.removeAll { $0.audiobookId == audiobookId }
                // Recalculate total storage
                totalStorageUsed = uploadedAudiobooks.reduce(0) { $0 + $1.fileSize }
                // Clear from tracking so transfer button becomes available again
                iOSWatchConnectivityManager.shared.clearCloudKitUploaded(audiobookId: audiobookId.uuidString)
            }

        } catch {
            await MainActor.run {
                errorMessage = "Failed to delete from CloudKit: \(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func clearAllData() async {
        guard let manager = transferManager else { return }

        isLoading = true
        defer { isLoading = false }

        var failed: [UploadedAudiobook] = []
        for uploaded in uploadedAudiobooks {
            do {
                try await manager.deleteAudiobookFromCloud(audiobookId: uploaded.audiobookId)
                // Clear from tracking so transfer button becomes available again
                iOSWatchConnectivityManager.shared.clearCloudKitUploaded(
                    audiobookId: uploaded.audiobookId.uuidString)
            } catch {
                AppLogger.cloudKit.error(
                    "Failed to delete \(uploaded.title): \(error.localizedDescription)")
                failed.append(uploaded)
            }
        }

        // Keep what couldn't be removed listed, and say so
        uploadedAudiobooks = failed
        totalStorageUsed = failed.reduce(0) { $0 + $1.fileSize }
        if !failed.isEmpty {
            errorMessage =
                "Couldn't remove \(failed.map(\.title).joined(separator: ", ")). Try again later."
            showingError = true
        }
    }
}

// MARK: - Supporting Types

struct UploadedAudiobook: Identifiable {
    let audiobookId: UUID
    let title: String
    let fileSize: Int64
    let uploadDate: Date

    var id: UUID { audiobookId }
}

struct UploadedAudiobookRow: View {
    let uploaded: UploadedAudiobook
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(uploaded.title)
                .font(.headline)

            HStack {
                Text(ByteCountFormatter.string(fromByteCount: uploaded.fileSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("•")
                    .foregroundStyle(.secondary)

                Text(uploaded.uploadDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    NavigationStack {
        CloudKitStorageView()
    }
    .modelContainer(for: [Audiobook.self])
}
