//
//  LibraryView.swift
//  Listen This
//
//  Main library view showing audiobook collection
//

import OSLog
import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.lastAccessedDate, order: .reverse) private var audiobooks: [Audiobook]
    @State private var connectivity: iOSWatchConnectivityManager?

    @Binding var selectedAudiobook: Audiobook?

    @State private var searchText = ""
    @State private var showingAddBook = false
    @State private var showingSettings = false

    // Sheet state - storing IDs instead of model objects
    @State private var deleteAudiobookId: UUID?
    @State private var transferAudiobookId: UUID?
    @State private var detailsAudiobookId: UUID?

    // Track books currently downloading
    @State private var downloadingBookIds: Set<UUID> = []

    var filteredAudiobooks: [Audiobook] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText)
                || book.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if let connectivity {
                sidebarContent(connectivity: connectivity)
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

    @ViewBuilder
    private func sidebarContent(connectivity: iOSWatchConnectivityManager) -> some View {
        List(filteredAudiobooks, selection: $selectedAudiobook) { book in
            LibraryRow(
                audiobook: book, connectivity: connectivity, downloadingBookIds: downloadingBookIds
            )
            .tag(book)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Info/Details action
                Button {
                    detailsAudiobookId = book.id
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .tint(.blue)

                // Delete action - always available
                Button(role: .destructive) {
                    deleteAudiobookId = book.id
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // Transfer to Watch (only for cached books)
                if connectivity.isPaired && connectivity.isWatchAppInstalled
                    && book.isFileCached
                {
                    Button {
                        transferAudiobookId = book.id
                    } label: {
                        Label("Transfer", systemImage: "applewatch")
                    }
                    .tint(.blue)
                }

                // Download for remote books that support downloading and aren't cached
                if book.requiresStreaming && book.sourceIdentifier != nil {
                    Button {
                        Task {
                            await downloadRemoteBook(book)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(.green)
                    .disabled(downloadingBookIds.contains(book.id))
                }
            }
            .contextMenu {
                contextMenuItems(for: book, connectivity: connectivity)
            }
        }
        .refreshable {
            await refreshLibrary()
        }
        .searchable(text: $searchText, prompt: "Search audiobooks")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
        .sheet(
            isPresented: .init(
                get: { deleteAudiobookId != nil },
                set: { if !$0 { deleteAudiobookId = nil } }
            )
        ) {
            if let id = deleteAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                DeleteAudiobookSheet(
                    audiobook: audiobook,
                    connectivity: connectivity,
                    modelContext: modelContext,
                    onDismiss: {
                        deleteAudiobookId = nil
                    }
                )
            }
        }
        .sheet(
            isPresented: .init(
                get: { transferAudiobookId != nil },
                set: { if !$0 { transferAudiobookId = nil } }
            )
        ) {
            if let id = transferAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                NavigationStack {
                    AutoTransferSheet(audiobook: audiobook)
                }
            }
        }
        .sheet(
            isPresented: .init(
                get: { detailsAudiobookId != nil },
                set: { if !$0 { detailsAudiobookId = nil } }
            )
        ) {
            if let id = detailsAudiobookId,
                let audiobook = audiobooks.first(where: { $0.id == id })
            {
                AudiobookDetailsSheet(audiobook: audiobook)
            }
        }
    }

    @ViewBuilder
    private func contextMenuItems(
        for audiobook: Audiobook, connectivity: iOSWatchConnectivityManager
    ) -> some View {
        // Send to Watch (only for cached books)
        if connectivity.isPaired && connectivity.isWatchAppInstalled && audiobook.isFileCached {
            Button {
                transferAudiobookId = audiobook.id
            } label: {
                Label("Send to Watch", systemImage: "applewatch")
            }
        }

        // Delete (only show if file exists)
        if audiobook.isFileCached || audiobook.iCloudRelativePath != nil {
            Button(role: .destructive) {
                deleteAudiobookId = audiobook.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func refreshLibrary() async {
        // Force a refresh by triggering SwiftData to re-evaluate queries
        // This is useful after downloads or external changes
        do {
            try modelContext.save()
        } catch {
            AppLogger.import.error("Failed to refresh library: \(error.localizedDescription)")
        }
    }

    private func downloadRemoteBook(_ audiobook: Audiobook) async {
        guard let identifier = audiobook.sourceIdentifier else {
            AppLogger.import.error("Missing source identifier for download")
            return
        }

        // Mark as downloading
        downloadingBookIds.insert(audiobook.id)
        defer {
            // Always remove from downloading set when done
            downloadingBookIds.remove(audiobook.id)
        }

        do {
            let downloadURL: URL

            // Get download URL based on source type
            switch audiobook.sourceType {
            case "audiobookshelf":
                guard let serverURL = URL(string: SettingsManager.shared.audiobookshelfServerURL)
                else {
                    AppLogger.import.error("Missing Audiobookshelf server URL")
                    return
                }

                guard let apiKey = loadAPIKeyFromKeychain() else {
                    AppLogger.import.error("Failed to load Audiobookshelf API key")
                    return
                }

                let provider = AudiobookshelfProvider()
                try await provider.authenticateWithAPIKey(serverURL: serverURL, apiKey: apiKey)
                downloadURL = try await provider.getStreamURL(identifier: identifier)

            case "jellyfin":
                // Future: Add Jellyfin support
                AppLogger.import.error("Jellyfin downloads not yet supported")
                return

            default:
                AppLogger.import.error("Unknown source type: \(audiobook.sourceType)")
                return
            }

            // Download the file
            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)

            // Move to cache
            let cacheManager = AudiobookCacheManager(modelContext: modelContext)
            let cacheURL = try cacheManager.cacheAudiobook(audiobook, from: localURL)

            if cacheURL.path != audiobook.expectedCachePath,
                let expectedPath = audiobook.expectedCachePath
            {
                let expectedURL = URL(fileURLWithPath: expectedPath)
                try? FileManager.default.removeItem(at: expectedURL)
                try FileManager.default.moveItem(at: cacheURL, to: expectedURL)
            }

            // Create or update CacheEntry to trigger UI update
            let fileSize =
                try FileManager.default.attributesOfItem(
                    atPath: audiobook.expectedCachePath ?? ""
                )[.size] as? Int64 ?? 0

            if let existingEntry = audiobook.cacheEntry {
                // Update existing entry
                existingEntry.lastAccessedDate = Date()
                existingEntry.fileSize = fileSize
            } else {
                // Create new cache entry
                let cacheEntry = CacheEntry(
                    filePath: audiobook.expectedCachePath ?? "",
                    fileSize: fileSize,
                    downloadedDate: Date(),
                    lastAccessedDate: Date()
                )
                cacheEntry.audiobook = audiobook
                audiobook.cacheEntry = cacheEntry
                modelContext.insert(cacheEntry)
            }

            try modelContext.save()

            AppLogger.import.info("Downloaded remote book: \(audiobook.title)")
        } catch {
            AppLogger.import.error(
                "Failed to download remote book: \(error.localizedDescription)")
        }
    }

    private func loadAPIKeyFromKeychain() -> String? {
        let service = "com.anarkisti.Listen-This.audiobookshelf"
        let account = "api-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return apiKey
    }
}

// MARK: - Library Row Component

struct LibraryRow: View {
    let audiobook: Audiobook
    let connectivity: iOSWatchConnectivityManager
    let downloadingBookIds: Set<UUID>

    var body: some View {
        HStack(spacing: 12) {
            // Artwork thumbnail
            if let artworkData = audiobook.artworkData,
                let image = UIImage(data: artworkData)
            {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "book.fill")
                            .foregroundStyle(.secondary)
                    }
            }

            // Book info
            VStack(alignment: .leading, spacing: 4) {
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Progress indicator
                if let session = audiobook.playbackSession,
                    session.currentPosition > 0
                {
                    ProgressView(value: session.currentPosition, total: audiobook.duration)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer()

            // Status icon in top-right corner
            VStack {
                statusIcon(for: audiobook)
                    .font(.title3)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIcon(for audiobook: Audiobook) -> some View {
        // Show spinner if downloading
        if downloadingBookIds.contains(audiobook.id) {
            ProgressView()
                .controlSize(.small)
        } else if audiobook.isFileCached {
            // If cached, no icon needed - it's available offline regardless of source
            EmptyView()
        } else if audiobook.requiresStreaming {
            // Not cached and requires network (any remote source)
            Image(systemName: "wifi")
                .foregroundStyle(.orange)
        } else if audiobook.iCloudRelativePath != nil {
            // iCloud book not yet downloaded
            Image(systemName: "icloud")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    @Previewable @State var selectedAudiobook: Audiobook?
    NavigationStack {
        LibraryView(selectedAudiobook: $selectedAudiobook)
            .modelContainer(for: [
                Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self,
            ])
    }
}
