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
                Text("CloudKit Storage")
            } footer: {
                Text(
                    "How much space is taken by the uploaded audiobooks."
                )
            }

            Section {
                if uploadedAudiobooks.isEmpty && !isLoading {
                    Text("No audiobooks uploaded to CloudKit")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
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
                Text("Uploaded Audiobooks")
            } footer: {
                Text(
                    "These audiobooks are uploaded to CloudKit and can be downloaded on your Apple Watch."
                )
            }

            Section {
                Button("Refresh Storage Info") {
                    Task {
                        await loadStorageInfo()
                    }
                }
                .disabled(isLoading)

                Button("Clear All CloudKit Data", role: .destructive) {
                    Task {
                        await clearAllData()
                    }
                }
                .disabled(isLoading || uploadedAudiobooks.isEmpty)
            }
        }
        .navigationTitle("CloudKit Storage")
        .navigationBarTitleDisplayMode(.inline)
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

        for uploaded in uploadedAudiobooks {
            do {
                try await manager.deleteAudiobookFromCloud(audiobookId: uploaded.audiobookId)
            } catch {
                AppLogger.cloudKit.error(
                    "Failed to delete \(uploaded.title): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            uploadedAudiobooks = []
            totalStorageUsed = 0
            isLoading = false
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

    @State private var showingDeleteConfirm = false

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
