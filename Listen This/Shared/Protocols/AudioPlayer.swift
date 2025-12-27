//
//  AudioPlayer.swift
//  Listen This
//
//  Protocol for audio playback operations
//

import Foundation

/// Protocol for audio player functionality
@MainActor
protocol AudioPlayer: AnyObject {

    var isPlaying: Bool { get }
    var currentPosition: Double { get }
    var duration: Double { get }
    var playbackRate: Double { get }
    var currentChapterIndex: Int { get }
    var loadError: Error? { get }

    var sleepTimerRemaining: TimeInterval { get }
    var isSleepTimerActive: Bool { get }

    var sortedChapters: [Chapter] { get }

    func load(audiobook: Audiobook) async

    func play() async
    func pause() async
    func seek(to position: Double) async -> Double
    func skip(by seconds: Double) async
    func setPlaybackRate(_ rate: Double)

    func previousChapter() async
    func nextChapter() async

    func setSleepTimer(minutes: Int)
    func cancelSleepTimer()
}
