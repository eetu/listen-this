//
//  AudioPlayerService.swift
//  Listen This (iOS + watchOS)
//
//  Single, compiling, cross-platform audio player service
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftData

// MARK: - Concrete Implementation

@MainActor
@Observable
final class AudioPlayerService: AudioPlayer {

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
                try AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                PlaybackDiagnostics.log("Failed to deactivate audio session: \(error)")
            }
        }
    }

    // MARK: - Shared Instance

    private static var _shared: AudioPlayerService?

    /// Returns the shared player service instance, creating it if necessary
    static func shared(modelContext: ModelContext) -> AudioPlayerService {
        if let existing = _shared {
            return existing
        }
        let service = AudioPlayerService(modelContext: modelContext)
        _shared = service
        return service
    }

    // MARK: - Core State

    private let modelContext: ModelContext
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private(set) var audiobook: Audiobook?

    /// Tracks the timestamp of the last restored/saved playback state
    /// Used to prevent older synced data from overwriting newer local progress
    private var lastKnownPlayedTimestamp: Date?

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
    private(set) var sleepAtEndOfChapter: Bool = false

    var isSleepTimerActive: Bool {
        sleepTimerEndTime != nil || sleepAtEndOfChapter
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
    }

    // MARK: - Chapters

    var sortedChapters: [Chapter] {
        audiobook?.chapters?.sorted { $0.index < $1.index } ?? []
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            try AudioSessionController.configure()
        } catch {
            PlaybackDiagnostics.log("Audio session configuration failed: \(error)")
        }
    }

    private func activateAudioSession() throws {
        try AudioSessionController.activate()
    }

    private func deactivateAudioSession() {
        AudioSessionController.deactivate()
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
        // Skip reload if this audiobook is already loaded and playing
        if self.audiobook?.id == audiobook.id, player != nil {
            PlaybackDiagnostics.log("Audiobook already loaded, skipping reload")
            return
        }

        cleanup()
        self.audiobook = audiobook
        loadError = nil

        do {
            let url = try await resolveFileURL(for: audiobook)
            print("[AudioPlayer] Creating asset for URL: \(url.path)")

            // For iCloud files, we need to coordinate access
            let asset: AVURLAsset
            if url.path.contains("Mobile Documents") {
                print("[AudioPlayer] Using file coordination for iCloud file")
                asset = try await loadAssetWithCoordination(from: url)
            } else {
                asset = AVURLAsset(url: url)
            }

            print("[AudioPlayer] Checking if asset is playable...")
            let isPlayable = try await asset.load(.isPlayable)
            print("[AudioPlayer] Asset isPlayable: \(isPlayable)")

            guard isPlayable else {
                print("[AudioPlayer] Asset is not playable")
                throw AudiobookError.fileNotFound
            }

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer

            let durationTime = try await asset.load(.duration)
            duration = durationTime.seconds
            print("[AudioPlayer] Loaded successfully, duration: \(duration)")

            // Observe player rate to keep isPlaying in sync with actual playback state
            setupRateObserver(for: newPlayer)

            restorePlaybackState()
            startTimeObserver()
            updateNowPlayingInfo()

        } catch {
            print("[AudioPlayer] Load error: \(error)")
            loadError = error
        }
    }

    private func loadAssetWithCoordination(from url: URL) async throws -> AVURLAsset {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?

            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
                let asset = AVURLAsset(url: coordinatedURL)
                continuation.resume(returning: asset)
            }

            if let error = coordinatorError {
                continuation.resume(throwing: error)
            }
        }
    }

    private func resolveFileURL(for audiobook: Audiobook) async throws -> URL {
        print("[AudioPlayer] Resolving file URL for: \(audiobook.title)")
        print("[AudioPlayer] - filename: \(audiobook.filename ?? "nil")")
        print("[AudioPlayer] - iCloudRelativePath: \(audiobook.iCloudRelativePath ?? "nil")")
        print("[AudioPlayer] - isFileCached: \(audiobook.isFileCached)")
        print("[AudioPlayer] - expectedCachePath: \(audiobook.expectedCachePath ?? "nil")")

        if audiobook.isFileCached, let cached = audiobook.cacheFileURL {
            print("[AudioPlayer] Using cached file: \(cached.path)")
            return cached
        }

        if let cloudURL = audiobook.iCloudFileURL {
            print("[AudioPlayer] Trying iCloud URL: \(cloudURL.path)")

            #if os(iOS)
            _ = cloudURL.startAccessingSecurityScopedResource()
            securityScopedURL = cloudURL
            #endif

            let fileExists = FileManager.default.fileExists(atPath: cloudURL.path)
            print("[AudioPlayer] File exists at iCloud path: \(fileExists)")

            // Check if file needs to be downloaded from iCloud
            if !fileExists {
                print("[AudioPlayer] Starting iCloud download...")
                try await downloadiCloudFile(at: cloudURL)
            }

            guard FileManager.default.fileExists(atPath: cloudURL.path) else {
                print("[AudioPlayer] File still not found after download attempt")
                throw AudiobookError.fileNotFound
            }
            return cloudURL
        }

        print("[AudioPlayer] No valid file URL found")
        throw AudiobookError.fileNotFound
    }

    private func downloadiCloudFile(at url: URL) async throws {
        // Trigger iCloud download
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        // Wait for download to complete (up to 5 minutes)
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if status?.ubiquitousItemDownloadingStatus == .current {
                return
            }

            // Check if file now exists
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
        }

        throw AudiobookError.downloadFailed
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

            // Start default sleep timer if configured
            if !isSleepTimerActive {
                let defaultTimer = SettingsManager.shared.defaultSleepTimer
                if defaultTimer == .endOfChapter {
                    setSleepTimerEndOfChapter()
                } else if let minutes = defaultTimer.minutes {
                    setSleepTimer(minutes: minutes)
                }
            }
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

    /// Skip backward using the configured interval from settings
    func skipBackward() async {
        let interval = Double(SettingsManager.shared.skipBackwardInterval)
        _ = await seek(to: currentPosition - interval)
    }

    /// Skip forward using the configured interval from settings
    func skipForward() async {
        let interval = Double(SettingsManager.shared.skipForwardInterval)
        _ = await seek(to: currentPosition + interval)
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

        // Use same tolerance as updateCurrentChapter for consistency
        let tolerance = 0.1

        if currentPosition - (chapter.startTime - tolerance) > 3 {
            await seek(to: chapter.startTime)
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            await seek(to: sortedChapters[currentChapterIndex].startTime)
        }
    }

    // MARK: - Rate Observer

    private func setupRateObserver(for player: AVPlayer) {
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in
                // Sync isPlaying with actual player state
                let shouldBePlaying = player.rate > 0
                if self.isPlaying != shouldBePlaying {
                    self.isPlaying = shouldBePlaying
                    PlaybackDiagnostics.log("Player rate changed, isPlaying synced to: \(shouldBePlaying)")
                }
            }
        }
    }

    // MARK: - Time Observer

    private func startTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentPosition = time.seconds
                self.updateCurrentChapter()

                if self.isPlaying && Int(time.seconds) % 5 == 0 {
                    self.updateNowPlayingInfo()
                    self.savePlaybackState()
                }
            }

        }
    }

    // MARK: - Now Playing / Remote Commands

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
            info[MPMediaItemPropertyAlbumTitle] =
                sortedChapters[currentChapterIndex].title
        }

        #if os(iOS)
        if let data = audiobook.artworkData,
           let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { await self?.play() }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            Task { await self?.pause() }
            return .success
        }

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
                if let rawOptions =
                    info[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                       .contains(.shouldResume) {
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
        guard let session = audiobook?.playbackSession else {
            // No existing session - use 1.0x speed
            playbackRate = 1.0
            return
        }
        currentPosition = session.currentPosition
        currentChapterIndex = session.currentChapter

        // Use per-book speed if enabled, otherwise use 1.0x
        if SettingsManager.shared.rememberSpeedPerBook {
            playbackRate = session.playbackRate
        } else {
            playbackRate = 1.0
        }

        lastKnownPlayedTimestamp = session.lastPlayed
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

        // Check if CloudKit synced newer data from another device
        // If the session's lastPlayed is newer than what we loaded,
        // and we haven't actually played yet (no local changes), don't overwrite
        if let knownTimestamp = lastKnownPlayedTimestamp,
           session.lastPlayed > knownTimestamp {
            // Remote has newer data - adopt it instead of overwriting
            PlaybackDiagnostics.log("Detected newer remote progress (\(session.lastPlayed) > \(knownTimestamp)), adopting remote state")
            currentPosition = session.currentPosition
            currentChapterIndex = session.currentChapter
            playbackRate = session.playbackRate
            lastKnownPlayedTimestamp = session.lastPlayed
            Task { await seek(to: currentPosition) }
            return
        }

        session.currentPosition = currentPosition
        session.currentChapter = currentChapterIndex
        session.playbackRate = playbackRate
        session.lastPlayed = Date()
        lastKnownPlayedTimestamp = session.lastPlayed
        session.progressPercentage =
            duration > 0 ? (currentPosition / duration) * 100 : 0

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
        let previousChapterIndex = currentChapterIndex

        // Use a small tolerance (100ms) to account for floating-point precision
        // and AVPlayer briefly reporting positions slightly before the exact seek target
        let tolerance = 0.1

        for chapter in sortedChapters.reversed() {
            if currentPosition >= chapter.startTime - tolerance {
                currentChapterIndex = chapter.index
                break
            }
        }

        // Check if chapter changed and we should sleep at end of chapter
        if sleepAtEndOfChapter && currentChapterIndex != previousChapterIndex && currentChapterIndex > previousChapterIndex {
            Task {
                await pause()
                cancelSleepTimer()
            }
        }
    }

    // MARK: - Sleep Timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEndTime =
            Date().addingTimeInterval(TimeInterval(minutes * 60))

        sleepTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let remaining =
                    self.sleepTimerEndTime?.timeIntervalSinceNow ?? 0
                if remaining <= 0 {
                    Task { await self.pause() }
                    self.cancelSleepTimer()
                } else {
                    self.sleepTimerRemaining = remaining
                }
            }
        }
    }

    /// Set sleep timer to pause at the end of the current chapter
    func setSleepTimerEndOfChapter() {
        cancelSleepTimer()
        sleepAtEndOfChapter = true
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndTime = nil
        sleepTimerRemaining = 0
        sleepAtEndOfChapter = false
    }

    // MARK: - Cleanup

    private func cleanup() {
        cancelSleepTimer()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        rateObserver?.invalidate()
        rateObserver = nil

        #if os(iOS)
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        #endif

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Update state to reflect that playback is stopped
        isPlaying = false

        player = nil
        audiobook = nil
    }
}
