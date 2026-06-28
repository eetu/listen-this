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

    /// Control icon sizes that scale with Dynamic Type
    @ScaledMetric(relativeTo: .title) private var skipIconSize: CGFloat = 30
    /// Tappable frame around the play/pause glyph, scales with the glyph
    @ScaledMetric(relativeTo: .largeTitle) private var playButtonSize: CGFloat = 60
    #if os(iOS)
        @ScaledMetric(relativeTo: .largeTitle) private var playIconSize: CGFloat = 60
    #elseif os(watchOS)
        @ScaledMetric(relativeTo: .largeTitle) private var playIconSize: CGFloat = 50
        /// Volume ring diameter; scales with the play button so the ring and
        /// glyph grow together instead of the ring being a fixed anchor.
        @ScaledMetric(relativeTo: .largeTitle) private var volumeRingSize: CGFloat = 80
    #endif

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
            let duration = max(player.duration, 0.01)
            return (min(max(player.currentPosition, 0), duration), duration)
        }

        let duration = max(chapter.duration, 0.01)
        // Cap elapsed at the chapter duration: at a chapter boundary position can
        // briefly exceed it before currentChapterIndex updates, which otherwise
        // overflows the progress bar / pushes the iOS Slider value out of range.
        let elapsed = min(max(0, player.currentPosition - chapter.startTime), duration)
        return (elapsed, duration)
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
                    .font(.caption2)
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
                .accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(formatTime(chapterProgress.elapsed)) of \(formatTime(chapterProgress.duration))"
                )
            #endif

            HStack {
                Text(formatTime(chapterProgress.elapsed))
                Spacer()
                Text(formatTime(chapterProgress.duration))
            }
            .font(.caption)
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
        .accessibilityLabel("Previous chapter")
    }

    private var nextChapterButton: some View {
        Button {
            Task { await player.nextChapter() }
        } label: {
            Image(systemName: "forward.fill")
                .font(skipFont)
        }
        .disabled(player.currentChapterIndex >= chapters.count - 1)
        .accessibilityLabel("Next chapter")
    }

    private var skipBackwardButton: some View {
        Button {
            Task { await player.skip(by: -Double(settings.skipBackwardInterval)) }
        } label: {
            Image(systemName: "gobackward.\(settings.skipBackwardInterval)")
                .font(skipFont)
        }
        .accessibilityLabel("Skip back \(settings.skipBackwardInterval) seconds")
    }

    private var skipForwardButton: some View {
        Button {
            Task { await player.skip(by: Double(settings.skipForwardInterval)) }
        } label: {
            Image(systemName: "goforward.\(settings.skipForwardInterval)")
                .font(skipFont)
        }
        .accessibilityLabel("Skip forward \(settings.skipForwardInterval) seconds")
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
                    VolumeRing(volume: volume, diameter: volumeRingSize)

                    // Play/Pause icon
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(playFont)
                        .frame(width: playButtonSize, height: playButtonSize)
                }
            #else
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(playFont)
                    .frame(width: playButtonSize, height: playButtonSize)
            #endif
        }
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }

    private var spacing: CGFloat {
        #if os(iOS)
            32
        #elseif os(watchOS)
            16
        #endif
    }

    private var skipFont: Font {
        .system(size: skipIconSize)
    }

    private var playFont: Font {
        .system(size: playIconSize)
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Volume Ring

#if os(watchOS)
    struct VolumeRing: View {
        let volume: Float
        var diameter: CGFloat = 80
        @State private var showRing = false
        @State private var hideTask: Task<Void, Never>?

        var body: some View {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
                    .frame(width: diameter, height: diameter)

                // Volume level ring
                Circle()
                    .trim(from: 0, to: showRing ? CGFloat(volume) : 0)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: diameter, height: diameter)
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
