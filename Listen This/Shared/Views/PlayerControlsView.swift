//
//  PlayerControlsView.swift
//  Listen This
//

import SwiftUI
import UIKit

// MARK: - View

struct PlayerControlsView<Player: AudioPlayer & Observable>: View {
    @Bindable var player: Player
    let audiobook: Audiobook

    /// Feature flags
    let showsChapterSkipButtons: Bool
    var showsChapterTitle: Bool = true

    /// Volume for visual feedback (watchOS only)
    #if os(watchOS)
        @Binding var volume: Float
    #endif

    /// Playback settings
    @State private var settings = SettingsManager.shared

    /// Progress color extracted from artwork
    @State private var progressColor: Color = .blue

    // MARK: - Computed

    private var chapters: [Chapter] {
        audiobook.chapters?.sorted(by: { $0.index < $1.index }) ?? []
    }

    private var currentChapter: Chapter? {
        guard
            player.currentChapterIndex >= 0,
            player.currentChapterIndex < chapters.count
        else { return nil }

        return chapters[player.currentChapterIndex]
    }

    private var chapterProgress: (elapsed: Double, duration: Double) {
        guard let chapter = currentChapter else {
            return (player.currentPosition, player.duration)
        }

        let elapsed = max(0, player.currentPosition - chapter.startTime)
        return (elapsed, max(chapter.duration, 0.01))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 6) {

            if showsChapterTitle, let chapter = currentChapter {
                ChapterTitleView(title: chapter.title)
            }

            progressView

            playbackButtons

            if let error = player.loadError {
                Text(error.localizedDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 32)
        .task(id: audiobook.id) {
            extractProgressColor()
        }
    }

    // MARK: - Helpers

    private func extractProgressColor() {
        guard let artworkData = audiobook.artworkData,
            let image = UIImage(data: artworkData),
            let dominantColor = image.dominantColor()
        else {
            progressColor = .blue
            return
        }
        progressColor = dominantColor
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 2) {

            #if os(watchOS)
                WatchProgressBar(
                    value: chapterProgress.elapsed,
                    total: chapterProgress.duration,
                    height: 7,
                    foregroundColor: progressColor,
                    backgroundColor: Color.white.opacity(0.2)
                )
            #endif

            #if os(iOS)
                Slider(
                    value: Binding(
                        get: { chapterProgress.elapsed },
                        set: { newValue in
                            let chapterStart = currentChapter?.startTime ?? 0
                            Task {
                                await player.seek(to: chapterStart + newValue)
                            }
                        }
                    ),
                    in: 0...max(chapterProgress.duration, 0.01)
                )
                .tint(progressColor)
            #endif

            HStack {
                Text(formatTime(chapterProgress.elapsed))
                Spacer()
                Text(formatTime(chapterProgress.duration))
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Buttons

    private var playbackButtons: some View {
        HStack(spacing: spacing) {

            if showsChapterSkipButtons {
                previousChapterButton
            }

            skipBackwardButton
            playPauseButton
            skipForwardButton

            if showsChapterSkipButtons {
                nextChapterButton
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    private var previousChapterButton: some View {
        Button {
            Task { await player.previousChapter() }
        } label: {
            Image(systemName: "backward.fill")
                .font(skipFont)
        }
        .disabled(player.currentChapterIndex == 0)
    }

    private var nextChapterButton: some View {
        Button {
            Task { await player.nextChapter() }
        } label: {
            Image(systemName: "forward.fill")
                .font(skipFont)
        }
        .disabled(player.currentChapterIndex >= chapters.count - 1)
    }

    private var skipBackwardButton: some View {
        Button {
            Task { await player.skip(by: -Double(settings.skipBackwardInterval)) }
        } label: {
            Image(systemName: "gobackward.\(settings.skipBackwardInterval)")
                .font(skipFont)
        }
    }

    private var skipForwardButton: some View {
        Button {
            Task { await player.skip(by: Double(settings.skipForwardInterval)) }
        } label: {
            Image(systemName: "goforward.\(settings.skipForwardInterval)")
                .font(skipFont)
        }
    }

    private var playPauseButton: some View {
        Button {
            Task {
                player.isPlaying
                    ? await player.pause()
                    : await player.play()
            }
        } label: {
            #if os(watchOS)
                ZStack {
                    // Volume ring
                    VolumeRing(volume: volume)

                    // Play/Pause icon
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(playFont)
                        .frame(width: 60, height: 60)
                }
            #else
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(playFont)
                    .frame(width: 60, height: 60)
            #endif
        }
    }

    private var spacing: CGFloat {
        #if os(iOS)
            32
        #elseif os(watchOS)
            16
        #endif
    }

    private var skipFont: Font {
        .system(size: 30)
    }

    private var playFont: Font {
        #if os(iOS)
            .system(size: 60)
        #elseif os(watchOS)
            .system(size: 50)
        #endif
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Volume Ring

#if os(watchOS)
    struct VolumeRing: View {
        let volume: Float
        @State private var showRing = false
        @State private var hideTask: Task<Void, Never>?

        var body: some View {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
                    .frame(width: 80, height: 80)

                // Volume level ring
                Circle()
                    .trim(from: 0, to: showRing ? CGFloat(volume) : 0)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: volume)
            }
            .opacity(showRing ? 1 : 0)
            .onChange(of: volume) { _, _ in
                showVolumeRing()
            }
        }

        private func showVolumeRing() {
            hideTask?.cancel()
            showRing = true

            hideTask = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled {
                    await MainActor.run {
                        showRing = false
                    }
                }
            }
        }
    }
#endif

//
// MARK: - Previews (Modern #Preview)
//

#if DEBUG

#if os(watchOS)
    #Preview("Paused · Middle Chapter") {
        @Previewable @State var volume: Float = 0.7
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: false,
                currentPosition: 180,
                duration: 510,
                currentChapterIndex: 1
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: false,
            volume: $volume
        )
        .padding()
    }
#else
    #Preview("Paused · Middle Chapter") {
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: false,
                currentPosition: 180,
                duration: 510,
                currentChapterIndex: 1
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: true
        )
        .padding()
    }
#endif

#if os(watchOS)
    #Preview("Playing · First Chapter") {
        @Previewable @State var volume: Float = 0.5
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: true,
                currentPosition: 45,
                duration: 510,
                currentChapterIndex: 0
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: false,
            volume: $volume
        )
        .padding()
    }
#else
    #Preview("Playing · First Chapter") {
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: true,
                currentPosition: 45,
                duration: 510,
                currentChapterIndex: 0
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: true
        )
        .padding()
    }
#endif

#if os(watchOS)
    #Preview("Error State · No Chapter Buttons") {
        @Previewable @State var volume: Float = 0.3
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: false,
                currentPosition: 0,
                duration: 0,
                currentChapterIndex: 0,
                loadError: NSError(
                    domain: "Preview",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to load audio"
                    ]
                )
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: false,
            volume: $volume
        )
        .padding()
    }
#else
    #Preview("Error State · No Chapter Buttons") {
        PlayerControlsView(
            player: MockAudioPlayerService(
                isPlaying: false,
                currentPosition: 0,
                duration: 0,
                currentChapterIndex: 0,
                loadError: NSError(
                    domain: "Preview",
                    code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to load audio"
                    ]
                )
            ),
            audiobook: PreviewData.audiobook,
            showsChapterSkipButtons: false
        )
        .padding()
    }
#endif

#endif // DEBUG
