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
    @AppStorage("audiobookshelfBrowserSortOption") private var sortOption: SortOption = .recentlyAdded
    @AppStorage("audiobookshelfBrowserSortAscending") private var sortAscending: Bool = false

    /// For previews: skip network loading and use provided data
    private let previewAudiobooks: [AudiobookMetadata]?

    init(previewAudiobooks: [AudiobookMetadata]? = nil) {
        self.previewAudiobooks = previewAudiobooks
    }

    enum SortOption: String, CaseIterable, RawRepresentable {
        case recentlyAdded = "Recently Added"
        case title = "Title"
        case author = "Author"
        case duration = "Duration"

        var systemImage: String {
            switch self {
            case .recentlyAdded: "clock"
            case .title: "textformat.abc"
            case .author: "person"
            case .duration: "timer"
            }
        }
    }

    var filteredAudiobooks: [AudiobookMetadata] {
        let filtered = if searchText.isEmpty {
            audiobooks
        } else {
            audiobooks.filter { book in
                book.title.localizedCaseInsensitiveContains(searchText)
                    || book.author.localizedCaseInsensitiveContains(searchText)
            }
        }

        let sorted = filtered.sorted { lhs, rhs in
            switch sortOption {
            case .recentlyAdded:
                lhs.addedDate > rhs.addedDate
            case .title:
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .author:
                lhs.author.localizedCaseInsensitiveCompare(rhs.author) == .orderedAscending
            case .duration:
                lhs.duration > rhs.duration
            }
        }

        return sortAscending ? sorted.reversed() : sorted
    }

    private var sortDescription: String {
        let direction = switch sortOption {
        case .recentlyAdded:
            sortAscending ? "Oldest first" : "Newest first"
        case .title:
            sortAscending ? "Z to A" : "A to Z"
        case .author:
            sortAscending ? "Z to A" : "A to Z"
        case .duration:
            sortAscending ? "Shortest first" : "Longest first"
        }
        return "\(sortOption.rawValue) · \(direction)"
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
                    List {
                        Section {
                            ForEach(filteredAudiobooks, id: \.identifier) { metadata in
                                AudiobookshelfRow(
                                    metadata: metadata,
                                    sortOption: sortOption,
                                    onAdd: { addToLibrary(metadata: metadata) },
                                    apiKey: SettingsManager.shared.audiobookshelfAPIKey
                                )
                            }
                        } header: {
                            Text(sortDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search Audiobookshelf library")
                }
            }
            .navigationTitle("Audiobookshelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                if sortOption == option {
                                    // Tap same option again: toggle direction
                                    sortAscending.toggle()
                                } else {
                                    // New option: reset to default direction
                                    sortOption = option
                                    sortAscending = false
                                }
                            } label: {
                                HStack {
                                    Label(option.rawValue, systemImage: option.systemImage)
                                    Spacer()
                                    if sortOption == option {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            if let previewAudiobooks {
                audiobooks = previewAudiobooks
            } else {
                loadLibrary()
            }
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
    let sortOption: AudiobookshelfBrowserView.SortOption
    let onAdd: () -> Void
    let apiKey: String

    @Environment(\.modelContext) private var modelContext
    @Query private var audiobooks: [Audiobook]

    @State private var isAdded = false
    @State private var artworkImage: UIImage?
    @State private var showingRemoveConfirmation = false

    private var secondaryInfo: String {
        switch sortOption {
        case .recentlyAdded:
            formatAddedDate(metadata.addedDate)
        case .author:
            metadata.author
        case .title, .duration:
            if let narrator = metadata.narrator {
                "Narrated by \(narrator)"
            } else {
                metadata.author
            }
        }
    }

    private func formatAddedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Added \(formatter.localizedString(for: date, relativeTo: Date()))"
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
                Text(metadata.title)
                    .font(.headline)
                    .lineLimit(2)

                // Show author when not sorting by author
                if sortOption != .author {
                    Text(metadata.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Context-aware secondary info
                Text(secondaryInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Show duration when sorting by duration
                if sortOption == .duration {
                    Text(formatDuration(metadata.duration))
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

#Preview("With Books") {
    AudiobookshelfBrowserView(previewAudiobooks: [
        AudiobookMetadata(
            identifier: "1",
            title: "Project Hail Mary",
            author: "Andy Weir",
            narrator: "Ray Porter",
            duration: 58200,
            fileSize: 580_000_000,
            sourceType: "audiobookshelf",
            sourceURL: "https://example.com/1",
            chapterCount: 32,
            addedDate: Date()
        ),
        AudiobookMetadata(
            identifier: "2",
            title: "The Martian",
            author: "Andy Weir",
            narrator: "R.C. Bray",
            duration: 40200,
            fileSize: 410_000_000,
            sourceType: "audiobookshelf",
            sourceURL: "https://example.com/2",
            chapterCount: 24,
            addedDate: Date().addingTimeInterval(-86400)
        ),
        AudiobookMetadata(
            identifier: "3",
            title: "Dune",
            author: "Frank Herbert",
            narrator: "Scott Brick",
            duration: 75600,
            fileSize: 750_000_000,
            sourceType: "audiobookshelf",
            sourceURL: "https://example.com/3",
            chapterCount: 48,
            addedDate: Date().addingTimeInterval(-172800)
        ),
        AudiobookMetadata(
            identifier: "4",
            title: "1984",
            author: "George Orwell",
            narrator: "Simon Prebble",
            duration: 36000,
            fileSize: 350_000_000,
            sourceType: "audiobookshelf",
            sourceURL: "https://example.com/4",
            chapterCount: 23,
            addedDate: Date().addingTimeInterval(-259200)
        ),
        AudiobookMetadata(
            identifier: "5",
            title: "Atomic Habits",
            author: "James Clear",
            duration: 19800,
            fileSize: 200_000_000,
            sourceType: "audiobookshelf",
            sourceURL: "https://example.com/5",
            chapterCount: 20,
            addedDate: Date().addingTimeInterval(-345600)
        ),
    ])
    .modelContainer(for: Audiobook.self)
}

#Preview("Empty Library") {
    AudiobookshelfBrowserView(previewAudiobooks: [])
        .modelContainer(for: Audiobook.self)
}

#Preview("Loading") {
    AudiobookshelfBrowserView()
        .modelContainer(for: Audiobook.self)
}
