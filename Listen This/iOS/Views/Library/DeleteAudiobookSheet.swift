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
    var connectivity: Connectivity
    let modelContext: ModelContext
    let onDismiss: () -> Void

    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    // Store all needed values at init time to avoid accessing detached objects
    private let audiobookId: UUID
    private let audiobookTitle: String
    private let isFileCached: Bool
    private let iCloudRelativePath: String?
    private let sourceIdentifier: String?
    
    private var hasICloudPath: Bool {
        iCloudRelativePath != nil
    }

    init(
        audiobook: Audiobook,
        connectivity: Connectivity,
        modelContext: ModelContext,
        onDismiss: @escaping () -> Void
    ) {
        self.connectivity = connectivity
        self.modelContext = modelContext
        self.onDismiss = onDismiss
        
        // Capture all values at init time
        self.audiobookId = audiobook.id
        self.audiobookTitle = audiobook.title
        self.isFileCached = audiobook.isFileCached
        self.iCloudRelativePath = audiobook.iCloudRelativePath
        self.sourceIdentifier = audiobook.sourceIdentifier
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Only show "Delete from iPhone" if file is cached locally
                    if isFileCached {
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
                            await deleteAudiobook(deleteFromiCloud: hasICloudPath)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: hasICloudPath ? "icloud.slash" : "trash")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(hasICloudPath ? "Delete Everywhere" : "Delete from Library")
                                    .font(.headline)

                                if hasICloudPath {
                                    // Stated unconditionally: whether the book
                                    // is on the Watch right now can't be known
                                    // reliably from here, and the delete
                                    // reaches every device either way.
                                    Text("Removes from iCloud, iPhone, and Apple Watch")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if sourceIdentifier != nil {
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
                    Text("Delete \"\(audiobookTitle)\"?")
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
                // Already deleted - just dismiss
                onDismiss()
                return
            }

            // IMPORTANT: Resolve artworkData fault before deletion
            // For CloudKit-synced books, the external storage might not be fully synced yet
            // We need to access it here to prevent "detached backing data" crash
            _ = audiobookToDelete.artworkData
            
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
