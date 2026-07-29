import AVKit
import SwiftData
import SwiftUI

// MARK: - Production Wrapper (for Navigation)

struct PlayerView: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @State private var player: AudioPlayerService?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let player, !isLoading {
                PlayerViewContent(audiobook: audiobook, player: player)
            } else {
                ProgressView("Loading...")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AirPlayButton()
                    .frame(width: 44, height: 44)
            }
        }
        .task(id: audiobook.id) {
            isLoading = true

            // Use the shared player service to ensure only one player is active
            let service = AudioPlayerService.shared(modelContext: modelContext)
            player = service

            // Load the new audiobook (this will cleanup the previous one)
            await service.load(audiobook: audiobook)

            isLoading = false
        }
    }
}

// MARK: - Generic Content View (Injectable)

struct PlayerViewContent<Player: AudioPlayer & Observable>: View {
    let audiobook: Audiobook

    @Bindable var player: Player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingChapters = false
    @State private var showingSpeedPicker = false
    @State private var showingSleepTimer = false

    var sortedChapters: [Chapter]? {
        audiobook.chapters?.sorted(by: { $0.index < $1.index })
    }

    var isPlaying: Bool {
        player.isPlaying
    }

    var currentChapter: Chapter? {
        guard
            let chapters = sortedChapters,
            player.currentChapterIndex >= 0,
            player.currentChapterIndex < chapters.count
        else { return nil }
        return chapters[player.currentChapterIndex]
    }

    /// iPad: regular horizontal AND regular vertical (true iPad, not iPhone landscape)
    private var isIPad: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// Landscape mode: vertical size class is compact (iPhone landscape or iPad split view)
    private var isLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        Group {
            if isIPad {
                // iPad: Centered layout with large artwork
                iPadPlayerLayout
            } else if isLandscape {
                // iPhone landscape (or narrow iPad): Side-by-side layout
                iPhoneLandscapeLayout
            } else {
                // iPhone portrait: Vertical layout
                iPhonePlayerLayout
            }
        }
        .toolbar {
            if isIPad {
                iPadToolbar
            } else if isLandscape {
                iPhoneLandscapeToolbar
            } else {
                iPhoneToolbar
            }
        }
        .sheet(isPresented: $showingChapters) {
            PlayerChaptersSheet(player: player, audiobook: audiobook)
        }
        .sheet(isPresented: $showingSpeedPicker) {
            PlayerSpeedSheet(player: player)
                .presentationDetents([.height(250)])
        }
        .sheet(isPresented: $showingSleepTimer) {
            SleepTimerSheet(player: player)
                .presentationDetents([.height(450)])
        }
    }

    // MARK: - iPad Layout

    private var iPadPlayerLayout: some View {
        VStack {
            Spacer()

            artworkView
                .frame(maxWidth: 500, maxHeight: 500)

            metadataSection
                .frame(maxWidth: 500)
                .padding(.top, 16)

            Spacer()

            PlayerControlsView(
                player: player,
                audiobook: audiobook,
                showsChapterSkipButtons: true
            )
            .frame(maxWidth: 600)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var iPadToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            HStack(spacing: 32) {
                Button {
                    showingChapters = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                        Text("Chapters")
                    }
                }
                Button {
                    showingSpeedPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        Text("Speed")
                    }
                }
                Button {
                    showingSleepTimer = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "moon")
                        Text("Sleep Timer")
                    }
                }
                .tint(player.isSleepTimerActive ? .accentColor : nil)
            }
            Spacer()
        }
    }

    // MARK: - iPhone Layout

    private var iPhonePlayerLayout: some View {
        VStack(spacing: 24) {
            artworkView
                .padding(.top, 8)
            Spacer()
            PlayerControlsView(
                player: player,
                audiobook: audiobook,
                showsChapterSkipButtons: true
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ToolbarContentBuilder
    private var iPhoneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                showingChapters = true
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
            Spacer()
            Button {
                showingSpeedPicker = true
            } label: {
                Label("Speed", systemImage: "gauge.with.dots.needle.67percent")
            }
            Spacer()
            Button {
                showingSleepTimer = true
            } label: {
                Label("Sleep Timer", systemImage: "moon")
            }
            .tint(player.isSleepTimerActive ? .accentColor : nil)
        }
    }

    @ToolbarContentBuilder
    private var iPhoneLandscapeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showingChapters = true
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
            Button {
                showingSpeedPicker = true
            } label: {
                Label("Speed", systemImage: "gauge.with.dots.needle.67percent")
            }
            Button {
                showingSleepTimer = true
            } label: {
                Label("Sleep Timer", systemImage: "moon")
            }
            .tint(player.isSleepTimerActive ? .accentColor : nil)
        }
    }

    // MARK: - iPhone Landscape Layout

    private var iPhoneLandscapeLayout: some View {
        GeometryReader { geometry in
            let artworkSize = geometry.size.height * 0.4

            VStack(spacing: 8) {
                // Top: Artwork and metadata side by side
                HStack(spacing: 16) {
                    artworkView
                        .frame(width: artworkSize, height: artworkSize)

                    VStack(spacing: 4) {
                        Text(audiobook.title)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(audiobook.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let chapter = currentChapter {
                            Text(chapter.title)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Bottom: Controls (no chapter title, shown above)
                PlayerControlsView(
                    player: player,
                    audiobook: audiobook,
                    showsChapterSkipButtons: true,
                    showsChapterTitle: false
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - Metadata Section (iPad)

    private var metadataSection: some View {
        VStack(spacing: 8) {
            Text(audiobook.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(audiobook.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Artwork (Shared)

    private var artworkView: some View {
        Group {
            if let data = audiobook.artworkData,
                let image = UIImage(data: data)
            {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.tertiary)
                    .overlay(Image(systemName: "book.closed").font(.largeTitle))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

// MARK: - AirPlay Button

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = UIColor(Color.primary)
        routePickerView.activeTintColor = UIColor(Color.primary)
        routePickerView.prioritizesVideoDevices = false
        routePickerView.accessibilityLabel = "AirPlay"

        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // No updates needed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AVRoutePickerView, context: Context)
        -> CGSize
    {
        // Provide explicit size to avoid Auto Layout conflicts
        return CGSize(width: 44, height: 44)
    }
}

// MARK: - Generic Sheet Wrappers

private struct PlayerChaptersSheet<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player
    let audiobook: Audiobook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let chapters = audiobook.chapters, !chapters.isEmpty {
                        ForEach(chapters.sorted(by: { $0.index < $1.index })) { chapter in
                            Button {
                                Task {
                                    let _ = await player.seek(to: chapter.startTime)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chapter.title)
                                            .font(.headline)

                                        Text("Chapter \(chapter.index + 1)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if chapter.index == player.currentChapterIndex {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .id(chapter.id)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Chapters",
                            systemImage: "list.bullet",
                            description: Text("This audiobook has no chapter metadata.")
                        )
                    }
                }
                .task {
                    // Scroll to current chapter after a brief delay to ensure list is rendered
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds

                    if let chapters = audiobook.chapters,
                        player.currentChapterIndex >= 0,
                        player.currentChapterIndex < chapters.count
                    {
                        let sortedChapters = chapters.sorted(by: { $0.index < $1.index })
                        if let currentChapter = sortedChapters.first(where: {
                            $0.index == player.currentChapterIndex
                        }) {
                            withAnimation {
                                proxy.scrollTo(currentChapter.id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PlayerSpeedSheet<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player
    @State private var selectedSpeed: Double

    private let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init(player: Player) {
        self.player = player
        _selectedSpeed = State(initialValue: player.playbackRate)
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Playback Speed")
                    .font(.headline)
                Spacer()
                Text("\(selectedSpeed, specifier: "%.2f")x")
                    .monospacedDigit()
            }
            .padding(.horizontal)

            // Range matches AudioPlayerService's clamp and the Watch's preset
            // list. At 2.5 the slider let you drag past what the player would
            // accept: the rate stopped at 2.0 while this sheet's label — which
            // reads local state, not the player — kept counting up to 2.50x.
            Slider(
                value: $selectedSpeed,
                in: 0.5...2.0,
                step: 0.05
            )
            .onChange(of: selectedSpeed) { _, newValue in
                player.setPlaybackRate(newValue)
            }
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 5), spacing: 12) {
                ForEach(presets, id: \.self) { speed in
                    Button {
                        selectedSpeed = speed
                        player.setPlaybackRate(speed)
                    } label: {
                        Text("\(speed, specifier: "%.2f")")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        abs(selectedSpeed - speed) < 0.01
                                            ? Color.accentColor : Color(.systemGray5))
                            )
                            .foregroundStyle(abs(selectedSpeed - speed) < 0.01 ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Playing with Chapters") {
    PlayerViewContent(
        audiobook: PreviewData.audiobook,
        player: MockAudioPlayerService(
            isPlaying: true,
            currentPosition: 145,
            duration: 510,
            currentChapterIndex: 1
        )
    )
}

#Preview("Paused at Start") {
    PlayerViewContent(
        audiobook: PreviewData.audiobook,
        player: MockAudioPlayerService(
            isPlaying: false,
            currentPosition: 0,
            duration: 510,
            currentChapterIndex: 0
        )
    )
}

#Preview("Error State") {
    PlayerViewContent(
        audiobook: PreviewData.audiobook,
        player: MockAudioPlayerService(
            isPlaying: false,
            currentPosition: 0,
            duration: 0,
            currentChapterIndex: 0,
            loadError: NSError(
                domain: "Preview",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load audio file"]
            )
        )
    )
}
#endif
