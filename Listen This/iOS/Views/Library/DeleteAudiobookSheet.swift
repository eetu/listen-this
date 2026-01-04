//
//  DeleteAudiobookSheet.swift
//  Listen This
//
//  Sheet for deleting audiobooks with options for local or cloud deletion
//

import OSLog
import SwiftData
import SwiftUI

struct DeleteAudiobookSheet<Connectivity: iOSWatchConnectivity & Observable>: View {
    let audiobook: Audiobook
    var connectivity: Connectivity
    let modelContext: ModelContext
    let onDismiss: () -> Void

    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    private let audiobookId: UUID
    private var isOnWatch: Bool {
        connectivity.watchCachedAudiobookIds.contains(audiobookId.uuidString)
    }

    init(
        audiobook: Audiobook,
        connectivity: Connectivity,
        modelContext: ModelContext,
        onDismiss: @escaping () -> Void
    ) {
        self.audiobook = audiobook
        self.connectivity = connectivity
        self.modelContext = modelContext
        self.onDismiss = onDismiss
        self.audiobookId = audiobook.id
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only show "Delete from iPhone" if file is cached locally
                    if audiobook.isFileCached {
                        Button(role: .destructive) {
                            Task {
                                await deleteAudiobook(deleteFromiCloud: false)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Delete from iPhone")
                                        .font(.headline)

                                    Text("Removes cached file from this device only")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    }

                    // Show "Delete Everywhere" for iCloud books, or "Delete from Library" for other sources
                    Button(role: .destructive) {
                        Task {
                            await deleteAudiobook(
                                deleteFromiCloud: audiobook.iCloudRelativePath != nil)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(
                                systemName: audiobook.iCloudRelativePath != nil
                                    ? "icloud.slash" : "trash"
                            )
                            .font(.title2)
                            .foregroundStyle(.red)
                            .frame(width: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    audiobook.iCloudRelativePath != nil
                                        ? "Delete Everywhere" : "Delete from Library"
                                )
                                .font(.headline)

                                if audiobook.iCloudRelativePath != nil {
                                    if isOnWatch {
                                        Text("Removes from iCloud, iPhone, and Apple Watch")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Removes from iCloud and all synced devices")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if audiobook.sourceIdentifier != nil {
                                    // Remote source (Audiobookshelf, Jellyfin, etc.)
                                    Text(
                                        "Removes from library. Book remains on the server and can be re-added later."
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("Removes from library and all synced devices")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                } header: {
                    Text("Delete \"\(audiobook.title)\"?")
                } footer: {
                    if isOnWatch {
                        Text(
                            "Audiobook is also on your Apple Watch. Deleting everywhere will remove it from Watch too."
                        )
                        .font(.caption2)
                    }
                }

                Section {
                    Button("Cancel", role: .cancel) {
                        onDismiss()
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle("Delete Audiobook")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
            .interactiveDismissDisabled(isDeleting)
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = ""
            }
        } message: {
            Text(deleteErrorMessage)
        }
    }

    @MainActor
    private func deleteAudiobook(deleteFromiCloud: Bool) async {
        isDeleting = true

        do {
            let descriptor = FetchDescriptor<Audiobook>(
                predicate: #Predicate { $0.id == audiobookId }
            )

            guard let audiobookToDelete = try modelContext.fetch(descriptor).first else {
                throw NSError(
                    domain: "DeleteAudiobookSheet",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Audiobook not found"]
                )
            }

            let service = AudiobookLibraryService(modelContext: modelContext)
            try await service.deleteAudiobook(
                audiobookToDelete,
                deleteFromiCloud: deleteFromiCloud
            )

            // Success - dismiss the sheet
            onDismiss()

        } catch {
            AppLogger.general.error("Deletion failed: \(error.localizedDescription)")
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
            isDeleting = false
        }
    }
}
