//
//  PlayerControlsView.swift
//  Listen This
//
//  Created by Eetu Sutinen on 21.12.2025.
//

import SwiftUI

struct PlayerControlsView: View {
    @Bindable var player: AudioPlayerService
    let chapters: [Chapter]

    /// Feature flags
    let showsChapterSkipButtons: Bool

    // MARK: - Computed

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

            if let chapter = currentChapter {
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
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 2) {

            /*
            #if os(watchOS)
            ProgressView(
                value: chapterProgress.elapsed,
                total: chapterProgress.duration
            )
            .controlSize(.mini)
            #endif

            #if os(iOS)
             */
            Slider(
                value: Binding(
                    get: {
                        chapterProgress.elapsed
                    },
                    set: { newValue in
                        let chapterStart = currentChapter?.startTime ?? 0
                        Task {
                            await player.seek(to: chapterStart + newValue)
                        }
                    }
                ),
                in: 0...max(chapterProgress.duration, 0.01)
            )
            //#endif

            HStack {
                Text(formatTime(chapterProgress.elapsed))
                Spacer()
                Text(formatTime(chapterProgress.duration))
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }
    // MARK: - Buttons

    private var playbackButtons: some View {
        HStack(spacing: 32) {

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
            Task { await player.skip(by: -15) }
        } label: {
            Image(systemName: "gobackward.15")
                .font(skipFont)
        }
    }

    private var skipForwardButton: some View {
        Button {
            Task { await player.skip(by: 30) }
        } label: {
            Image(systemName: "goforward.30")
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
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(playFont)
        }
    }

    private var skipFont: Font {
        .system(size: 30)
    }

    private var playFont: Font {
        .system(size: 60)
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
