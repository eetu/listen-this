//
//  LibraryView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity

// MARK: - Production Wrapper (for Navigation)

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) private var audiobooks: [Audiobook]
    @State private var connectivity: iOSWatchConnectivityManager?

    var body: some View {
        Group {
            if let connectivity {
                LibraryViewContent(
                    audiobooks: audiobooks,
                    connectivity: connectivity,
                    modelContext: modelContext
                )
            } else {
                ProgressView("Loading...")
            }
        }
        .task {
            if connectivity == nil {
                let manager = iOSWatchConnectivityManager.shared
                manager.configure(modelContext: modelContext)
                connectivity = manager
            }
        }
    }
}

// MARK: - Generic Content View (Injectable)

struct LibraryViewContent<Connectivity: iOSWatchConnectivity & Observable>: View {
    let audiobooks: [Audiobook]
    @Bindable var connectivity: Connectivity
    let modelContext: ModelContext

    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var showingSettings = false

    // Sheet state - storing IDs instead of model objects to avoid SwiftData issues
    @State private var deleteAudiobookId: UUID?
    @State private var transferAudiobookId: UUID?
    @State private var cloudKitAudiobookId: UUID?
    @State private var bluetoothAudiobookId: UUID?

    var filteredAudiobooks: [Audiobook] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText) ||
            book.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if audiobooks.isEmpty {
                    emptyStateView
                } else {
                    libraryList
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search audiobooks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingAddBook = true
                    } label: {
                        Label("Add Book", systemImage: "plus")
                    }

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingAddBook) {
                ImportView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .environment(connectivity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Audiobooks", systemImage: "book.closed")
        } description: {
            Text("Add audiobooks from iCloud Drive, Jellyfin, or AudiobookShelf")
        } actions: {
            Button("Add Audiobook") {
                showingAddBook = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Library List

    private var libraryList: some View {
        List {
            ForEach(filteredAudiobooks) { book in
                AudiobookCardWithMenu(
                    audiobook: book,
                    connectivity: connectivity,
                    modelContext: modelContext,
                    onDeleteTapped: { audiobook in
                        deleteAudiobookId = audiobook.id
                    },
                    onTransferTapped: { audiobook in
                        transferAudiobookId = audiobook.id
                    }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .id(book.id)
            }
        }
        .listStyle(.plain)
        .animation(.default, value: filteredAudiobooks.count)
        .navigationDestination(for: Audiobook.self) { book in
            PlayerView(audiobook: book)
        }
        .sheet(isPresented: .init(
            get: { deleteAudiobookId != nil },
            set: { if !$0 { deleteAudiobookId = nil } }
        )) {
            if let id = deleteAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                DeleteOptionsSheet(
                    audiobook: audiobook,
                    connectivity: connectivity,
                    modelContext: modelContext,
                    onDismiss: {
                        deleteAudiobookId = nil
                    }
                )
            }
        }
        .sheet(isPresented: .init(
            get: { transferAudiobookId != nil },
            set: { if !$0 { transferAudiobookId = nil } }
        )) {
            if let id = transferAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                TransferMethodSheet(
                    audiobook: audiobook,
                    onSelectCloudKit: {
                        cloudKitAudiobookId = id
                        transferAudiobookId = nil
                    },
                    onSelectBluetooth: {
                        bluetoothAudiobookId = id
                        transferAudiobookId = nil
                    },
                    onCancel: {
                        transferAudiobookId = nil
                    }
                )
            }
        }
        .sheet(isPresented: .init(
            get: { cloudKitAudiobookId != nil },
            set: { if !$0 { cloudKitAudiobookId = nil } }
        )) {
            if let id = cloudKitAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                NavigationStack {
                    CloudKitTransferView(audiobook: audiobook)
                }
            }
        }
        .sheet(isPresented: .init(
            get: { bluetoothAudiobookId != nil },
            set: { if !$0 { bluetoothAudiobookId = nil } }
        )) {
            if let id = bluetoothAudiobookId,
               let audiobook = audiobooks.first(where: { $0.id == id }) {
                NavigationStack {
                    SingleAudiobookTransferView(audiobook: audiobook)
                        .environment(connectivity)
                }
            }
        }
    }
}

// MARK: - Audiobook Card

// Wrapper view that manages the card, navigation, and context menu together
struct AudiobookCardWithMenu<Connectivity: iOSWatchConnectivity & Observable>: View {
    let audiobook: Audiobook
    var connectivity: Connectivity
    let modelContext: ModelContext
    let onDeleteTapped: (Audiobook) -> Void
    let onTransferTapped: (Audiobook) -> Void

    @State private var showDeleteError = false
    @State private var deleteErrorMessage = ""

    // CRITICAL: Capture audiobook ID at initialization to prevent SwiftData identity issues
    private let audiobookId: UUID

    // Cache the transfer states to prevent unnecessary re-renders
    @State private var hasActiveTransfer = false
    @State private var isOnWatch = false

    init(
        audiobook: Audiobook,
        connectivity: Connectivity,
        modelContext: ModelContext,
        onDeleteTapped: @escaping (Audiobook) -> Void,
        onTransferTapped: @escaping (Audiobook) -> Void
    ) {
        self.audiobook = audiobook
        self.connectivity = connectivity
        self.modelContext = modelContext
        self.onDeleteTapped = onDeleteTapped
        self.onTransferTapped = onTransferTapped
        self.audiobookId = audiobook.id // Capture ID immediately
    }

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(value: audiobook) {
                AudiobookCard(audiobook: audiobook)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                // Transfer to Watch
                if connectivity.isPaired && connectivity.isWatchAppInstalled {
                    if hasActiveTransfer {
                        Button {
                            connectivity.cancelTransfer(for: audiobookId.uuidString)
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .tint(.orange)
                    } else if isOnWatch {
                        Button {
                            removeFromAppleWatch()
                        } label: {
                            Label("Remove", systemImage: "applewatch.slash")
                        }
                        .tint(.purple)
                    } else {
                        Button {
                            onTransferTapped(audiobook)
                        } label: {
                            Label("Send to Watch", systemImage: "applewatch")
                        }
                        .tint(.blue)
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Delete action
                if audiobook.isFileCached || audiobook.iCloudRelativePath != nil {
                    Button(role: .destructive) {
                        onDeleteTapped(audiobook)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = ""
            }
        } message: {
            Text(deleteErrorMessage)
        }
        // Update cached states only when relevant connectivity values change
        .onAppear {
            updateCachedStates()
        }
        .onChange(of: connectivity.activeTransfers[audiobookId.uuidString]) { _, _ in
            hasActiveTransfer = connectivity.activeTransfers[audiobookId.uuidString] != nil
        }
        .onChange(of: connectivity.watchCachedAudiobookIds.contains(audiobookId.uuidString)) { _, newValue in
            isOnWatch = newValue
        }
    }

    private func updateCachedStates() {
        hasActiveTransfer = connectivity.activeTransfers[audiobookId.uuidString] != nil
        isOnWatch = connectivity.watchCachedAudiobookIds.contains(audiobookId.uuidString)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        // Watch transfer options (if Watch is paired and app installed)
        if connectivity.isPaired && connectivity.isWatchAppInstalled {
            if hasActiveTransfer {
                Button(role: .destructive) {
                    connectivity.cancelTransfer(for: audiobookId.uuidString)
                } label: {
                    Label("Cancel Transfer", systemImage: "xmark.circle")
                }
            } else if isOnWatch {
                Button {
                    removeFromAppleWatch()
                } label: {
                    Label("Remove from Watch", systemImage: "applewatch.slash")
                }
            } else {
                Button {
                    onTransferTapped(audiobook)
                } label: {
                    Label("Send to Watch", systemImage: "applewatch")
                }
            }

            Divider()
        }

        // Delete options (always available if file exists)
        if audiobook.isFileCached || audiobook.iCloudRelativePath != nil {
            Button(role: .destructive) {
                onDeleteTapped(audiobook)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func removeFromAppleWatch() {
        guard let session = connectivity.session, session.isReachable else {
            deleteErrorMessage = "Apple Watch is not reachable. Make sure it's nearby and unlocked."
            showDeleteError = true
            return
        }

        // Send delete command to Watch
        let message: [String: Any] = [
            "command": "deleteAudiobook",
            "audiobookId": audiobookId.uuidString
        ]

        session.sendMessage(message, replyHandler: { response in
            Task { @MainActor in
                if let success = response["success"] as? Bool, success {
                    // Update the cached book list
                    self.connectivity.watchCachedAudiobookIds.remove(self.audiobookId.uuidString)
                } else {
                    let errorMsg = response["error"] as? String ?? "Unknown error"
                    print("[LibraryView] Watch deletion failed: \(errorMsg)")
                    self.deleteErrorMessage = "Failed to delete from Watch: \(errorMsg)"
                    self.showDeleteError = true
                }
            }
        }) { error in
            Task { @MainActor in
                print("[LibraryView] Watch message failed: \(error)")
                self.deleteErrorMessage = "Failed to communicate with Watch: \(error.localizedDescription)"
                self.showDeleteError = true
            }
        }
    }
}

// MARK: - Audiobook Card (Presentation Only)

struct AudiobookCard: View {
    let audiobook: Audiobook

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            Group {
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.tertiary)

                        Image(systemName: "book.closed")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2)

            // Book info
            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)

                // Author
                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Progress indicator
                if let session = audiobook.playbackSession {
                    HStack(spacing: 6) {
                        ProgressView(value: session.progressPercentage, total: 100)
                            .tint(.accentColor)
                    }
                }
            }
            
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Transfer Method Sheet

struct TransferMethodSheet: View {
    let audiobook: Audiobook
    let onSelectCloudKit: () -> Void
    let onSelectBluetooth: () -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var cloudKitAvailability: ChunkAvailability = .notUploaded
    @State private var isCheckingAvailability = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isCheckingAvailability {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        // CloudKit transfer (fast, recommended)
                        Button {
                            onSelectCloudKit()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "icloud.and.arrow.up")
                                    .font(.title2)
                                    .foregroundStyle(cloudKitAvailability == .fullyUploaded ? .gray : .blue)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("iCloud WiFi Transfer")
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text("Fast")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }

                                    Text(cloudKitAvailabilitySubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if cloudKitAvailability != .fullyUploaded {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(cloudKitAvailability == .fullyUploaded)

                        // Bluetooth transfer (legacy)
                        Button {
                            onSelectBluetooth()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "iphone.and.arrow.forward")
                                    .font(.title2)
                                    .foregroundStyle(.purple)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("Bluetooth Transfer")
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text("Slow")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    }

                                    Text("Direct transfer from iPhone via Bluetooth")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Send \"\(audiobook.title)\" to Apple Watch")
                }

                Section {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                }
            }
            .navigationTitle("Transfer Method")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium])
            .interactiveDismissDisabled(false)
        }
        .task {
            await checkCloudKitAvailability()
        }
    }

    private var cloudKitAvailabilitySubtitle: String {
        switch cloudKitAvailability {
        case .fullyUploaded:
            return "Already uploaded to iCloud"
        case .partiallyUploaded:
            return "Resume partial upload over WiFi"
        case .notUploaded:
            return "Uses temporary iCloud space for faster transfer over WiFi"
        }
    }

    private func checkCloudKitAvailability() async {
        let transferManager = CloudKitChunkedTransferManager(modelContext: modelContext)
        cloudKitAvailability = await transferManager.checkCloudKitChunks(for: audiobook)
        isCheckingAvailability = false
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

// MARK: - Previews

#Preview("Library with Books") {
    @Previewable @State var connectivity = PreviewiOSWatchConnectivity()

    return LibraryViewContent(
        audiobooks: PreviewData.audiobooks,
        connectivity: connectivity,
        modelContext: PreviewModelContext.shared
    )
}

#Preview("Empty Library") {
    @Previewable @State var connectivity = PreviewiOSWatchConnectivity()

    return LibraryViewContent(
        audiobooks: [],
        connectivity: connectivity,
        modelContext: PreviewModelContext.shared
    )
}
