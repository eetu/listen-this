import SwiftUI
import SwiftData
import AVKit

// MARK: - Production Wrapper (for Navigation)

struct PlayerView: View {
    let audiobook: Audiobook
    
    @Environment(\.modelContext) private var modelContext
    @State private var player: AudioPlayerService?
    
    var body: some View {
        Group {
            if let player {
                PlayerViewContent(audiobook: audiobook, player: player)
            } else {
                ProgressView("Loading...")
            }
        }
        .toolbar {
            AirPlayButton()
        }
        .task {
            if player == nil {
                let service = AudioPlayerService(modelContext: modelContext)
                player = service
            }
        }
    }
}

// MARK: - Generic Content View (Injectable)

struct PlayerViewContent<Player: AudioPlayer & Observable>: View {
    let audiobook: Audiobook
    
    @Bindable var player: Player
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

    var body: some View {
        VStack(spacing: 24) {
            artworkView
                .padding(.top, 8)
            Spacer()
            if let sortedChapters {
                PlayerControlsView(
                    player: player,
                    chapters: sortedChapters,
                    showsChapterSkipButtons: true
                )
                .padding(.bottom, 16)
            }
        }
        .padding(.all, 16)
        .task {
            await player.load(audiobook: audiobook)
        }
        .onDisappear {
            Task { await player.pause() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button{ showingChapters = true }
                    label: {
                        Label("Chapters", systemImage: "list.bullet")
                    }
                Spacer()
                Button{ showingSpeedPicker = true }
                    label: {
                        Label("Speed", systemImage: "gauge.with.dots.needle.67percent")
                    }
                Spacer()
                Button { showingSleepTimer = true }
                    label: {
                        Label("Sleep Timer", systemImage: "moon")
                    }
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
            PlayerSleepTimerSheet(player: player)
                .presentationDetents([.height(250)])
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let data = audiobook.artworkData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.tertiary)
                    .overlay(Image(systemName: "book.closed").font(.largeTitle))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - AirPlay Button

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = UIColor(Color.primary)
        routePickerView.activeTintColor = UIColor(Color.primary)
        routePickerView.prioritizesVideoDevices = false

        // Constrain the size to match other toolbar icons
        routePickerView.setContentHuggingPriority(.required, for: .horizontal)
        routePickerView.setContentCompressionResistancePriority(.required, for: .horizontal)

        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // No updates needed
    }
}

// MARK: - Generic Sheet Wrappers

private struct PlayerChaptersSheet<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player
    let audiobook: Audiobook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                    }
                } else {
                    ContentUnavailableView(
                        "No Chapters",
                        systemImage: "list.bullet",
                        description: Text("This audiobook has no chapter metadata.")
                    )
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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

            Slider(
                value: $selectedSpeed,
                in: 0.5...2.5,
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
                                    .fill(abs(selectedSpeed - speed) < 0.01 ? Color.accentColor : Color(.systemGray5))
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

private struct PlayerSleepTimerSheet<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player
    @Environment(\.dismiss) private var dismiss

    private let presets: [Int] = [5, 10, 15, 30, 45, 60]

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Text("Sleep Timer")
                    .font(.headline)

                Spacer()

                if player.isSleepTimerActive {
                    Text(formattedRemaining)
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 12) {
                ForEach(presets, id: \.self) { minutes in
                    Button {
                        player.setSleepTimer(minutes: minutes)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(minutes)")
                                .font(.title2.bold())
                            Text("minutes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            if player.isSleepTimerActive {
                Button(role: .destructive) {
                    player.cancelSleepTimer()
                    dismiss()
                } label: {
                    Text("Cancel Sleep Timer")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red.opacity(0.15))
                        )
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
    }

    private var formattedRemaining: String {
        let remaining = Int(player.sleepTimerRemaining)
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

// MARK: - Previews

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


