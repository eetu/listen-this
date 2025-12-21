//
//  AudioPlayerService.swift
//  listen this (iOS + watchOS)
//
//  Single, compiling, cross-platform audio player service
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftData

#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class AudioPlayerService {

    // MARK: - Diagnostics (DEBUG only)

    private enum PlaybackDiagnostics {
        static func log(_ message: String) {
            #if DEBUG
            print("[SharedAudioPlayer] \(message)")
            #endif
        }
    }

    // MARK: - Audio Session Controller

    private enum AudioSessionController {
        static func configure() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: []
            )
        }

        static func activate() throws {
            try AVAudioSession.sharedInstance().setActive(true)
        }

        static func deactivate() {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                PlaybackDiagnostics.log("Failed to deactivate audio session: \(error)")
            }
        }
    }

    // MARK: - Core State

    private let modelContext: ModelContext
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var audiobook: Audiobook?

    var isPlaying = false
    var currentPosition: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1.0
    var currentChapterIndex: Int = 0
    var loadError: Error?

    #if os(iOS)
    private var securityScopedURL: URL?
    #endif

    // MARK: - Sleep Timer

    private var sleepTimer: Timer?
    private(set) var sleepTimerEndTime: Date?
    var sleepTimerRemaining: TimeInterval = 0

    var isSleepTimerActive: Bool {
        sleepTimerEndTime != nil
    }

    // MARK: - Init / Deinit

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        setupAudioSession()
        setupNotifications()
        setupRemoteCommandCenter()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        //cleanup()
    }

    // MARK: - Chapters

    var sortedChapters: [Chapter] {
        audiobook?.chapters?.sorted { $0.index < $1.index } ?? []
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            try AudioSessionController.configure()
            PlaybackDiagnostics.log("Audio session configured")
        } catch {
            PlaybackDiagnostics.log("Audio session configuration failed: \(error)")
        }
    }

    private func activateAudioSession() throws {
        try AudioSessionController.activate()
        PlaybackDiagnostics.log("Audio session activated")
    }

    private func deactivateAudioSession() {
        AudioSessionController.deactivate()
        PlaybackDiagnostics.log("Audio session deactivated")
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let nc = NotificationCenter.default

        nc.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        nc.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    // MARK: - Loading

    func load(audiobook: Audiobook) async {
        cleanup()
        self.audiobook = audiobook
        loadError = nil

        do {
            let url = try resolveFileURL(for: audiobook)
            let asset = AVURLAsset(url: url)

            guard try await asset.load(.isPlayable) else {
                throw AudiobookError.fileNotFound
            }

            let item = AVPlayerItem(asset: asset)
            player = AVPlayer(playerItem: item)

            let durationTime = try await asset.load(.duration)
            duration = durationTime.seconds

            restorePlaybackState()
            startTimeObserver()
            updateNowPlayingInfo()

        } catch {
            loadError = error
        }
    }

    private func resolveFileURL(for audiobook: Audiobook) throws -> URL {
        if audiobook.isFileCached, let cached = audiobook.cacheFileURL {
            return cached
        }

        if let cloudURL = audiobook.iCloudFileURL {
            #if os(iOS)
            _ = cloudURL.startAccessingSecurityScopedResource()
            securityScopedURL = cloudURL
            #endif

            guard FileManager.default.fileExists(atPath: cloudURL.path) else {
                throw AudiobookError.fileNotFound
            }
            return cloudURL
        }

        throw AudiobookError.fileNotFound
    }

    // MARK: - Playback Controls

    func play() async {
        guard let player else { return }

        do {
            try activateAudioSession()
            player.rate = Float(playbackRate)
            isPlaying = true
            updateLastPlayed()
            updateNowPlayingInfo()
        } catch {
            PlaybackDiagnostics.log("Play failed: \(error)")
        }
    }

    func pause() async {
        player?.pause()
        isPlaying = false
        savePlaybackState()
        updateNowPlayingInfo()
        deactivateAudioSession()
    }

    @discardableResult
    func seek(to position: Double) async -> Double {
        let clamped = max(0, min(duration, position))
        await player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentPosition = clamped
        updateCurrentChapter()
        savePlaybackState()
        return clamped
    }

    func skip(by seconds: Double) async {
        _ = await seek(to: currentPosition + seconds)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 2.0)
        if isPlaying {
            player?.rate = Float(playbackRate)
        }
        savePlaybackState()
    }

    // MARK: - Chapters

    func nextChapter() async {
        guard currentChapterIndex < sortedChapters.count - 1 else { return }
        currentChapterIndex += 1
        await seek(to: sortedChapters[currentChapterIndex].startTime)
    }

    func previousChapter() async {
        guard !sortedChapters.isEmpty else { return }
        let chapter = sortedChapters[currentChapterIndex]

        if currentPosition - chapter.startTime > 3 {
            await seek(to: chapter.startTime)
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            await seek(to: sortedChapters[currentChapterIndex].startTime)
        }
    }

    // MARK: - Time Observer

    private func startTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentPosition = time.seconds
            self.updateCurrentChapter()

            if self.isPlaying && Int(time.seconds) % 5 == 0 {
                self.updateNowPlayingInfo()
                self.savePlaybackState()
            }
        }
    }

    // MARK: - Now Playing

    private func updateNowPlayingInfo() {
        guard let audiobook else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: audiobook.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]

        if !audiobook.author.isEmpty {
            info[MPMediaItemPropertyArtist] = audiobook.author
        }

        if currentChapterIndex < sortedChapters.count {
            info[MPMediaItemPropertyAlbumTitle] = sortedChapters[currentChapterIndex].title
        }

        #if os(iOS)
        if let data = audiobook.artworkData,
           let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { await self?.play() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { await self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task {
                guard let self else { return }
                self.isPlaying ? await self.pause() : await self.play()
            }
            return .success
        }
    }

    // MARK: - Interruptions / Route Changes

    @objc private func handleInterruption(notification: Notification) {
        guard
            let info = notification.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        Task {
            switch type {
            case .began:
                await pause()
            case .ended:
                if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    await play()
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard
            let info = notification.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        if reason == .oldDeviceUnavailable {
            Task { await pause() }
        }
    }

    // MARK: - Persistence

    private func restorePlaybackState() {
        guard let session = audiobook?.playbackSession else { return }
        currentPosition = session.currentPosition
        currentChapterIndex = session.currentChapter
        playbackRate = session.playbackRate
        Task { await seek(to: currentPosition) }
    }

    private func savePlaybackState() {
        guard let audiobook else { return }

        let session = audiobook.playbackSession ?? {
            let s = PlaybackSession()
            audiobook.playbackSession = s
            modelContext.insert(s)
            return s
        }()

        session.currentPosition = currentPosition
        session.currentChapter = currentChapterIndex
        session.playbackRate = playbackRate
        session.lastPlayed = Date()
        session.progressPercentage = duration > 0 ? (currentPosition / duration) * 100 : 0

        if duration - currentPosition < 30 {
            session.isCompleted = true
        }

        try? modelContext.save()
    }

    private func updateLastPlayed() {
        audiobook?.lastAccessedDate = Date()
        try? modelContext.save()
    }

    private func updateCurrentChapter() {
        for chapter in sortedChapters.reversed() {
            if currentPosition >= chapter.startTime {
                currentChapterIndex = chapter.index
                break
            }
        }
    }

    // MARK: - Sleep Timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEndTime = Date().addingTimeInterval(TimeInterval(minutes * 60))

        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let remaining = self.sleepTimerEndTime?.timeIntervalSinceNow ?? 0
            if remaining <= 0 {
                Task { await self.pause() }
                self.cancelSleepTimer()
            } else {
                self.sleepTimerRemaining = remaining
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndTime = nil
        sleepTimerRemaining = 0
    }

    // MARK: - Cleanup

    private func cleanup() {
        cancelSleepTimer()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if os(iOS)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player = nil
        audiobook = nil
    }
}
