//
//  PreviewPlayerService.swift
//  Listen This
//
//  Created by Eetu Sutinen on 23.12.2025.
//

import MediaPlayer
import SwiftData

@MainActor
@Observable
final class PreviewAudioPlayerService: AudioPlayer {

    var isPlaying: Bool
    var currentPosition: Double
    var duration: Double
    var playbackRate: Double = 1.0
    var currentChapterIndex: Int
    var loadError: Error?
    var sleepTimerRemaining: TimeInterval = 0
    var isSleepTimerActive: Bool = false
    var sortedChapters: [Chapter] = []

    init(
        isPlaying: Bool,
        currentPosition: Double,
        duration: Double,
        currentChapterIndex: Int,
        loadError: Error? = nil
    ) {
        self.isPlaying = isPlaying
        self.currentPosition = currentPosition
        self.duration = duration
        self.currentChapterIndex = currentChapterIndex
        self.loadError = loadError
    }

    // MARK: - No-op async API

    func load(audiobook: Audiobook) async {}
    func play() async {}
    func pause() async {}
    func seek(to _: Double) async -> Double { 0 }
    func skip(by _: Double) async {}
    func setPlaybackRate(_ rate: Double) {}
    func previousChapter() async {}
    func nextChapter() async {}
    func setSleepTimer(minutes: Int) {}
    func cancelSleepTimer() {}
}
