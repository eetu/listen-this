//
//  AudiobookshelfBrowserView.swift
//  Listen This
//
//  Browse and add audiobooks from Audiobookshelf server
//

import OSLog
import SwiftData
import SwiftUI

struct AudiobookshelfBrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var provider = AudiobookshelfProvider()
    @State private var audiobooks: [AudiobookMetadata] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    var filteredAudiobooks: [AudiobookMetadata] {
        if searchText.isEmpty {
            return audiobooks
        }
        return audiobooks.filter { book in
            book.title.localizedCaseInsensitiveContains(searchText)
                || book.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading library...")
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            loadLibrary()
                        }

                        Button("Settings") {
                            // Dismiss browser so user can access settings from main view
                            dismiss()
                        }
                    }
                } else if audiobooks.isEmpty {
                    ContentUnavailableView {
                        Label("No Audiobooks", systemImage: "book")
                    } description: {
                        Text("Your Audiobookshelf library is empty")
                    }
                } else {
                    List(filteredAudiobooks, id: \.identifier) { metadata in
                        AudiobookshelfRow(metadata: metadata, onAdd: {
                            addToLibrary(metadata: metadata)
                        }, apiKey: SettingsManager.shared.audiobookshelfAPIKey)
                    }
                    .searchable(text: $searchText, prompt: "Search Audiobookshelf library")
                }
            }
            .navigationTitle("Audiobookshelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            loadLibrary()
        }
    }

    private func loadLibrary() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Authenticate with the CloudKit-synced server settings
                let authenticated = try await AudiobookshelfProvider.authenticatedFromSettings()

                // Fetch library
                let items = try await authenticated.fetchLibrary()

                await MainActor.run {
                    // Keep the authenticated provider around: rows reuse it for
                    // artwork and chapter fetches after the list appears.
                    provider = authenticated
                    audiobooks = items
                    isLoading = false
                }

            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func addToLibrary(metadata: AudiobookMetadata) {
        // Check if already exists
        let sourceId = metadata.identifier
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate<Audiobook> { book in
                book.sourceType == "audiobookshelf" && book.sourceIdentifier == sourceId
            }
        )

        if (try? modelContext.fetch(descriptor).first) != nil {
            AppLogger.import.info("Audiobook already in library: \(metadata.title)")
            return
        }

        // Create new audiobook
        let audiobook = Audiobook(
            title: metadata.title,
            author: metadata.author,
            narrator: metadata.narrator,
            duration: metadata.duration,
            fileSize: metadata.fileSize,
            chapterCount: 0  // Will be updated after fetching actual chapters
        )

        audiobook.sourceType = "audiobookshelf"
        audiobook.sourceIdentifier = metadata.identifier
        audiobook.sourceURL = metadata.sourceURL

        // Initialize chapters array
        audiobook.chapters = []

        modelContext.insert(audiobook)

        // Fetch full metadata with chapters and artwork
        Task {
            do {
                // Fetch and save artwork
                let artworkData = try await provider.getArtwork(identifier: metadata.identifier)
                audiobook.artworkData = artworkData

                // Create chapters from Audiobookshelf tracks
                await fetchAndCreateChapters(for: audiobook, identifier: metadata.identifier)

                // Update the chapter count after chapters are created
                audiobook.chapterCount = audiobook.chapters?.count ?? 0

                try? modelContext.save()
                AppLogger.import.info(
                    "Added Audiobookshelf audiobook with \(audiobook.chapterCount) chapters: \(metadata.title)"
                )
            } catch {
                AppLogger.import.error(
                    "Failed to fetch full metadata: \(error.localizedDescription)")
                // Book is still added, just without chapters/artwork
                try? modelContext.save()
            }
        }

        do {
            try modelContext.save()
            AppLogger.import.info("Added Audiobookshelf audiobook: \(metadata.title)")
        } catch {
            AppLogger.import.error("Failed to save audiobook: \(error.localizedDescription)")
        }
    }

    private func fetchAndCreateChapters(for audiobook: Audiobook, identifier: String) async {
        do {
            AppLogger.import.info(
                "Fetching chapters for audiobook: \(audiobook.title) (id: \(identifier))")

            // Use the provider's getChapters method (provider is already authenticated)
            let chapterInfos = try await provider.getChapters(identifier: identifier)

            AppLogger.import.info(
                "Received \(chapterInfos.count) chapter infos from Audiobookshelf")

            // Create Chapter objects from the chapter info
            for chapterInfo in chapterInfos {
                let chapter = Chapter(
                    index: chapterInfo.index,
                    title: chapterInfo.title,
                    startTime: chapterInfo.startTime,
                    duration: chapterInfo.duration
                )

                // Set the relationship
                chapter.audiobook = audiobook

                modelContext.insert(chapter)

                // Append to audiobook's chapters array
                if audiobook.chapters == nil {
                    audiobook.chapters = []
                }
                audiobook.chapters?.append(chapter)
            }

            AppLogger.import.info(
                "Created \(chapterInfos.count) chapters for \(audiobook.title). Audiobook.chapters count: \(audiobook.chapters?.count ?? 0)"
            )

        } catch {
            AppLogger.import.error("Failed to fetch chapters: \(error.localizedDescription)")
        }
    }
}

// MARK: - Audiobookshelf Row

struct AudiobookshelfRow: View {
    let metadata: AudiobookMetadata
    let onAdd: () -> Void
    let apiKey: String

    @Environment(\.modelContext) private var modelContext
    @Query private var audiobooks: [Audiobook]

    @State private var isAdded = false
    @State private var artworkImage: UIImage?
    @State private var showingRemoveConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Artwork with checkmark overlay
            ZStack(alignment: .center) {
                Group {
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.3))
                            .overlay {
                                Image(systemName: "book")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(isAdded ? 0.4 : 1.0)

                // Large checkmark overlay when added
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white, .green)
                        .shadow(radius: 2)
                }
            }
            .task {
                await loadArtwork()
                checkIfAlreadyAdded()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(metadata.title)
                        .font(.headline)
                        .lineLimit(2)
                }

                Text(metadata.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let narrator = metadata.narrator {
                    Text("Narrated by \(narrator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isAdded ? .secondary : .primary)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isAdded {
                // Confirm before removing — an accidental row tap should not
                // silently delete a book from the library (and via CloudKit,
                // from every device).
                showingRemoveConfirmation = true
            } else {
                // Add to library
                onAdd()
                isAdded = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isAdded ? "Double-tap to remove from library" : "Double-tap to add to library")
        .confirmationDialog(
            "Remove from Library?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { removeFromLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(metadata.title)\" will be removed from your library on all your devices.")
        }
    }

    private func checkIfAlreadyAdded() {
        // Check if this audiobook already exists in the library
        let sourceId = metadata.identifier
        isAdded = audiobooks.contains { book in
            book.sourceType == "audiobookshelf" && book.sourceIdentifier == sourceId
        }
    }

    private func removeFromLibrary() {
        // Find and delete the audiobook
        let sourceId = metadata.identifier

        // Fetch the audiobook to delete
        let descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate<Audiobook> { book in
                book.sourceType == "audiobookshelf" && book.sourceIdentifier == sourceId
            }
        )

        if let existingBook = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existingBook)
            try? modelContext.save()
            isAdded = false
            AppLogger.import.info("Removed Audiobookshelf audiobook: \(metadata.title)")
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func loadArtwork() async {
        guard let artworkURL = metadata.artworkURL else {
            AppLogger.import.debug("No artwork URL for \(metadata.title)")
            return
        }

        var request = URLRequest(url: artworkURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        artworkImage = image
                    }
                }
            }
        } catch {
            // Artwork loading failed, just show placeholder
        }
    }
}

#Preview {
    AudiobookshelfBrowserView()
        .modelContainer(for: Audiobook.self)
}
