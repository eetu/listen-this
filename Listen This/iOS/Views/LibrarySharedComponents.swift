//
//  LibrarySharedComponents.swift
//  Listen This
//
//  Shared components for library views
//

import SwiftUI
import SwiftData

// MARK: - Auto Transfer View

struct AutoTransferView: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selector: TransferMethodSelector?
    @State private var selectedMethod: SelectedMethod?
    @State private var isTransferring = false
    @State private var transferError: Error?
    @State private var showError = false
    @State private var cloudKitManager: CloudKitChunkedTransferManager?

    var body: some View {
        VStack(spacing: 20) {
            if let selectedMethod {
                // Show selected method
                VStack(spacing: 12) {
                    Image(systemName: methodIcon(selectedMethod))
                        .font(.system(size: 48))
                        .foregroundStyle(methodColor(selectedMethod))

                    Text(methodTitle(selectedMethod))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(methodDescription(selectedMethod))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()

                if isTransferring {
                    transferProgressView
                } else {
                    Button {
                        Task {
                            await performTransfer()
                        }
                    } label: {
                        Text("Start Transfer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(methodColor(selectedMethod))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Selecting best method...")
            }
        }
        .navigationTitle("Transfer to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Transfer Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {
                transferError = nil
            }
        } message: {
            if let error = transferError {
                Text(error.localizedDescription)
            }
        }
        .task {
            if selector == nil {
                let newSelector = TransferMethodSelector(modelContext: modelContext)
                selector = newSelector
                selectedMethod = newSelector.selectMethod(for: audiobook)

                // Initialize CloudKit manager for progress tracking
                cloudKitManager = CloudKitChunkedTransferManager(modelContext: modelContext)
            }
        }
        .interactiveDismissDisabled(isTransferring)
    }

    private func performTransfer() async {
        guard let selectedMethod, let manager = cloudKitManager else { return }

        isTransferring = true
        do {
            // Execute transfer based on selected method
            switch selectedMethod {
            case .cloudKit:
                #if os(iOS)
                // iPhone: Upload to CloudKit with progress tracking
                try await manager.uploadAudiobook(audiobook)
                #else
                // Watch: Download from CloudKit with progress tracking
                _ = try await manager.downloadAudiobook(audiobook)
                #endif

            case .watchConnectivity:
                #if os(iOS)
                // Direct transfer via WatchConnectivity
                // Ensure file is cached first
                if !audiobook.isFileCached {
                    let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                    _ = try await audiobook.downloadAndCache(using: cacheManager)
                }

                let watchConnectivityManager = iOSWatchConnectivityManager.shared
                try await watchConnectivityManager.transferAudiobook(audiobook)
                #else
                throw TransferError.methodUnavailable
                #endif

            case .iCloudDirect:
                // Direct iCloud download
                let cacheManager = AudiobookCacheManager(modelContext: modelContext)
                _ = try await audiobook.downloadAndCache(using: cacheManager)

            case .error(let reason):
                throw TransferError.noMethodAvailable(reason)
            }

            await MainActor.run {
                dismiss()
            }
        } catch {
            await MainActor.run {
                transferError = error
                showError = true
                isTransferring = false
            }
        }
    }

    private func methodIcon(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit:
            return "icloud.and.arrow.up"
        case .watchConnectivity:
            return "applewatch"
        case .iCloudDirect:
            return "icloud.and.arrow.down"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private func methodColor(_ method: SelectedMethod) -> Color {
        switch method {
        case .cloudKit:
            return .blue
        case .watchConnectivity:
            return .purple
        case .iCloudDirect:
            return .green
        case .error:
            return .red
        }
    }

    private func methodTitle(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit:
            return "CloudKit Transfer"
        case .watchConnectivity:
            return "Direct Transfer"
        case .iCloudDirect:
            return "iCloud Download"
        case .error:
            return "Transfer Error"
        }
    }

    private func methodDescription(_ method: SelectedMethod) -> String {
        switch method {
        case .cloudKit(let reason):
            return reason
        case .watchConnectivity(let reason):
            return reason
        case .iCloudDirect(let reason):
            return reason
        case .error(let reason):
            return reason
        }
    }

    @ViewBuilder
    private var transferProgressView: some View {
        VStack(spacing: 16) {
            // Check for CloudKit upload progress
            if let manager = cloudKitManager,
               let progress = manager.activeUploads[audiobook.id] {
                VStack(spacing: 12) {
                    // Progress bar
                    ProgressView(value: progress.progress) {
                        Text(progress.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        HStack {
                            Text("\(progress.progressPercentage)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(progress.progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .progressViewStyle(.linear)
                }
                .padding(.horizontal)
            } else if let manager = cloudKitManager,
                      let progress = manager.activeDownloads[audiobook.id] {
                // Download progress (for Watch)
                VStack(spacing: 12) {
                    ProgressView(value: progress.progress) {
                        Text(progress.statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } currentValueLabel: {
                        HStack {
                            Text("\(progress.progressPercentage)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(progress.progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .progressViewStyle(.linear)
                }
                .padding(.horizontal)
            } else {
                // Generic progress spinner for non-CloudKit transfers
                ProgressView("Transferring...")
                    .padding()
            }
        }
        .padding()
    }
}

// MARK: - Delete Options Sheet

struct DeleteOptionsSheet<Connectivity: iOSWatchConnectivity & Observable>: View {
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

                    // Always show "Delete Everywhere" if book exists in iCloud
                    if audiobook.iCloudRelativePath != nil {
                        Button(role: .destructive) {
                            Task {
                                await deleteAudiobook(deleteFromiCloud: true)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "icloud.slash")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Delete Everywhere")
                                        .font(.headline)

                                    if isOnWatch {
                                        Text("Removes from iCloud, iPhone, and Apple Watch")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Removes from iCloud and all synced devices")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                    }
                } header: {
                    Text("Delete \"\(audiobook.title)\"?")
                } footer: {
                    if isOnWatch {
                        Text("Audiobook is also on your Apple Watch. Deleting everywhere will remove it from Watch too.")
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
                    domain: "DeleteOptionsSheet",
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
            print("[DeleteOptionsSheet] Deletion failed: \(error)")
            deleteErrorMessage = error.localizedDescription
            showDeleteError = true
            isDeleting = false
        }
    }
}
