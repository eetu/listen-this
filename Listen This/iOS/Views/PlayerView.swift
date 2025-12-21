import SwiftUI
import SwiftData

struct PlayerView: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @State private var playerService: AudioPlayerService?
    @State private var showingChapters = false
    @State private var showingSpeedPicker = false
    @State private var showingSleepTimer = false

    
    var sortedChapters: [Chapter]? {
        audiobook.chapters?.sorted(by: { $0.index < $1.index })
    }
    
    var isPlaying: Bool {
        playerService?.isPlaying ?? false
    }

    var currentChapter: Chapter? {
        guard
            let chapters = sortedChapters,
            let index = playerService?.currentChapterIndex,
            index >= 0,
            index < chapters.count
        else { return nil }
        return chapters[index]
    }

    var body: some View {
        VStack(spacing: 24) {
            artworkView
                .padding(.top, 24)
            Spacer()
            if let playerService, let sortedChapters {
                PlayerControlsView(
                    player: playerService,
                    chapters: sortedChapters,
                    showsChapterSkipButtons: true
                )
            }
        }
        .padding(.bottom, 24)
        .task {
            if playerService == nil {
                let service = AudioPlayerService(modelContext: modelContext)
                playerService = service
                await service.load(audiobook: audiobook)
            }
        }
        .onDisappear {
            Task { await playerService?.pause() }
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
            ChaptersListView(audiobook: audiobook, playerService: playerService)
        }
        .sheet(isPresented: $showingSpeedPicker) {
            PlaybackSpeedPickerView(playerService: playerService)
                .presentationDetents([.height(250)])
        }
        .sheet(isPresented: $showingSleepTimer) {
            SleepTimerView(playerService: playerService)
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
