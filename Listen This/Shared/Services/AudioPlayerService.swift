//
//  AudioPlayerService.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation
import AVFoundation
import MediaPlayer
import SwiftData
import Combine

/// Service for managing audio playback using AVFoundation
@MainActor
@Observable
final class AudioPlayerService {
    
    // MARK: - Properties
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var audiobook: Audiobook?
    private var currentFileURL: URL?  // Track current file for security-scoped access
    private var sleepTimer: Timer?
    private let modelContext: ModelContext
    
    // Observable state
    var isPlaying = false
    var currentPosition: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1.0
    var currentChapterIndex: Int = 0
    var sleepTimerEndTime: Date?
    var sleepTimerRemaining: TimeInterval = 0
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        setupAudioSession()
        setupNotifications()
        setupRemoteCommandCenter()
    }
    
    deinit {
        // Can't call MainActor methods from deinit, so do minimal cleanup
        NotificationCenter.default.removeObserver(self)
        
        // Note: player and timeObserver will be deallocated automatically
        // The currentFileURL security scope will be released when the URL is deallocated
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
        } catch {
            // Failed to setup audio session
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }
    
    // MARK: - Remote Command Center Setup
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.play()
            }
            return .success
        }
        
        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.pause()
            }
            return .success
        }
        
        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                self.togglePlayback()
            }
            return .success
        }
        
        // Skip forward (30 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                await self.skipForward(30)
            }
            return .success
        }
        
        // Skip backward (15 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                await self.skipBackward(15)
            }
            return .success
        }
        
        // Next chapter
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                await self.nextChapter()
            }
            return .success
        }
        
        // Previous chapter
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            Task { @MainActor in
                await self.previousChapter()
            }
            return .success
        }
        
        // Seek position (scrubbing)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            
            Task { @MainActor in
                await self.seek(to: event.positionTime)
            }
            return .success
        }
        
        print("🎮 [AudioPlayer] Remote Command Center configured")
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                play()
            }
        @unknown default:
            break
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones were unplugged, pause playback
            pause()
        default:
            break
        }
    }
    
    // MARK: - Playback Control
    
    /// Load an audiobook for playback
    func loadAudiobook(_ audiobook: Audiobook) async throws {
        // Stop current playback if any
        stop()
        
        self.audiobook = audiobook
        
        // Try to get the file URL - first from cache, then from iCloud
        let fileURL: URL
        
        if let cachedURL = audiobook.cacheFileURL {
            // Use cached file if available
            fileURL = cachedURL
            print("🎵 [AudioPlayer] Using cached file: \(fileURL.path)")
        } else if let iCloudURL = audiobook.iCloudFileURL {
            // Use iCloud file
            fileURL = iCloudURL
            print("🎵 [AudioPlayer] Using iCloud file: \(fileURL.path)")
        } else {
            throw AudiobookError.fileNotFound
        }
        
        // Start accessing security-scoped resource for iCloud files
        let didStartAccessing = fileURL.startAccessingSecurityScopedResource()
        
        // For iCloud Drive files, check if file is downloaded
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory)
        
        if !fileExists {
            // Try to start downloading from iCloud
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                
                // Wait a moment for download to start
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                // Check again
                let existsNow = FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
                
                if !existsNow {
                    if didStartAccessing {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                    throw AudiobookError.fileNotFound
                }
            } catch {
                if didStartAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
                throw AudiobookError.fileNotFound
            }
        }
        
        // Store the file URL for later cleanup
        currentFileURL = fileURL
        
        // Create asset with options to reduce system queries
        let asset = AVURLAsset(
            url: fileURL,
            options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: false
            ]
        )
        let playerItem = AVPlayerItem(asset: asset)
        
        // Create player
        player = AVPlayer(playerItem: playerItem)
        
        // Load duration
        let durationTime = try await asset.load(.duration)
        duration = CMTimeGetSeconds(durationTime)
        
        // Restore playback position
        if let session = audiobook.playbackSession {
            currentPosition = session.currentPosition
            currentChapterIndex = session.currentChapter
            playbackRate = session.playbackRate
            
            let seekTime = CMTime(seconds: session.currentPosition, preferredTimescale: 600)
            await player?.seek(to: seekTime)
        }
        
        // Setup time observer
        setupTimeObserver()
        
        // Setup end notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        // Update Now Playing info
        updateNowPlayingInfo()
    }
    
    // MARK: - Now Playing Info
    
    private func updateNowPlayingInfo() {
        guard let audiobook = audiobook else { return }
        
        var nowPlayingInfo = [String: Any]()
        
        // Basic metadata
        nowPlayingInfo[MPMediaItemPropertyTitle] = audiobook.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = audiobook.author
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = audiobook.narrator ?? ""
        
        // Artwork
        if let artworkData = audiobook.artworkData,
           let image = UIImage(data: artworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        // Playback info
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        
        // Chapter info
        if let chapter = currentChapter {
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterNumber] = currentChapterIndex + 1
            nowPlayingInfo[MPNowPlayingInfoPropertyChapterCount] = audiobook.chapters?.count ?? 0
        }
        
        // Media type (audiobook)
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        
        print("📱 [AudioPlayer] Updated Now Playing info: \(audiobook.title)")
    }
    
    /// Start or resume playback
    func play() {
        guard let player = player else {
            return
        }
        
        // Ensure audio session is active
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setActive(true)
        } catch {
            // Failed to activate audio session
        }
        
        player.rate = Float(playbackRate)
        isPlaying = true
        updateLastPlayedDate()
        updateNowPlayingInfo()
    }
    
    /// Pause playback
    func pause() {
        player?.pause()
        isPlaying = false
        savePlaybackState()
        updateNowPlayingInfo()
    }
    
    /// Stop playback and cleanup
    func stop() {
        player?.pause()
        isPlaying = false
        savePlaybackState()
        cleanup()
    }
    
    /// Toggle play/pause state
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // MARK: - Seeking
    
    /// Seek to a specific position in seconds
    func seek(to position: Double) async {
        guard let player = player else { return }
        
        let seekTime = CMTime(seconds: position, preferredTimescale: 600)
        await player.seek(to: seekTime)
        currentPosition = position
        
        updateCurrentChapter()
        savePlaybackState()
    }
    
    /// Skip backward by specified seconds (default: 15)
    func skipBackward(_ seconds: Double = 15) async {
        let newPosition = max(0, currentPosition - seconds)
        await seek(to: newPosition)
    }
    
    /// Skip forward by specified seconds (default: 30)
    func skipForward(_ seconds: Double = 30) async {
        let newPosition = min(duration, currentPosition + seconds)
        await seek(to: newPosition)
    }
    
    // MARK: - Chapter Navigation
    
    /// Jump to the previous chapter
    /// If more than 3 seconds into current chapter, goes to start of current chapter first
    func previousChapter() async {
        guard let audiobook = audiobook,
              let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              !chapters.isEmpty else {
            return
        }
        
        let currentChapter = chapters[currentChapterIndex]
        let positionInChapter = currentPosition - currentChapter.startTime
        
        // If we're more than 3 seconds into the current chapter, go to its start
        if positionInChapter > 3.0 {
            await seek(to: currentChapter.startTime)
            return
        }
        
        // Otherwise, go to the previous chapter
        let targetIndex = max(0, currentChapterIndex - 1)
        if targetIndex < chapters.count {
            let chapter = chapters[targetIndex]
            await seek(to: chapter.startTime)
            currentChapterIndex = targetIndex
        }
    }
    
    /// Jump to the next chapter
    func nextChapter() async {
        guard let audiobook = audiobook,
              let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              !chapters.isEmpty else {
            return
        }
        
        let targetIndex = min(chapters.count - 1, currentChapterIndex + 1)
        if targetIndex < chapters.count {
            let chapter = chapters[targetIndex]
            await seek(to: chapter.startTime)
            currentChapterIndex = targetIndex
        }
    }
    
    /// Jump to a specific chapter by index
    func jumpToChapter(at index: Int) async {
        guard let audiobook = audiobook,
              let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              index >= 0 && index < chapters.count else {
            return
        }
        
        let chapter = chapters[index]
        await seek(to: chapter.startTime)
        currentChapterIndex = index
    }
    
    // MARK: - Playback Speed
    
    /// Set playback speed (0.5x - 2.0x)
    func setPlaybackRate(_ rate: Double) {
        let clampedRate = min(max(rate, 0.5), 2.0)
        playbackRate = clampedRate
        
        if isPlaying {
            player?.rate = Float(clampedRate)
        }
        
        savePlaybackState()
    }
    
    // MARK: - Time Observer
    
    private func setupTimeObserver() {
        // Remove existing observer
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        
        // Add periodic time observer (updates every 0.5 seconds)
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                Task { @MainActor in
                    self.currentPosition = seconds
                    self.updateCurrentChapter()
                    
                    // Update Now Playing info every 2 seconds
                    if self.isPlaying && Int(seconds) % 2 == 0 {
                        self.updateNowPlayingInfo()
                    }
                    
                    // Auto-save every 5 seconds during playback
                    if self.isPlaying && Int(seconds) % 5 == 0 {
                        self.savePlaybackState()
                    }
                }
            }
        }
    }
    
    // MARK: - State Management
    
    private func updateCurrentChapter() {
        guard let audiobook = audiobook,
              let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              !chapters.isEmpty else {
            return
        }
        
        // Find the current chapter based on position
        for (index, chapter) in chapters.enumerated() {
            let chapterEnd = chapter.startTime + chapter.duration
            if currentPosition >= chapter.startTime && currentPosition < chapterEnd {
                currentChapterIndex = index
                break
            }
        }
    }
    
    private func savePlaybackState() {
        guard let audiobook = audiobook else { return }
        
        // Get or create playback session
        let session: PlaybackSession
        if let existingSession = audiobook.playbackSession {
            session = existingSession
        } else {
            session = PlaybackSession()
            audiobook.playbackSession = session
        }
        
        // Update session
        session.currentPosition = currentPosition
        session.currentChapter = currentChapterIndex
        session.playbackRate = playbackRate
        session.lastSynced = Date()
        session.progressPercentage = duration > 0 ? (currentPosition / duration) * 100 : 0
        
        // Mark as completed if within 30 seconds of the end
        if duration - currentPosition < 30 {
            session.isCompleted = true
        }
        
        // Save context
        do {
            try modelContext.save()
        } catch {
            // Failed to save playback state
        }
    }
    
    private func updateLastPlayedDate() {
        guard let audiobook = audiobook else { return }
        audiobook.lastAccessedDate = Date()
        
        if let session = audiobook.playbackSession {
            session.lastPlayed = Date()
        }
        
        try? modelContext.save()
    }
    
    @objc private func playerDidFinishPlaying() {
        isPlaying = false
        savePlaybackState()
        
        // Mark as completed
        if let session = audiobook?.playbackSession {
            session.isCompleted = true
            try? modelContext.save()
        }
    }
    
    // MARK: - Sleep Timer
    
    /// Set a sleep timer to pause playback after specified minutes
    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        
        let endTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndTime = endTime
        
        // Create timer that fires every second to update remaining time
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let endTime = self.sleepTimerEndTime {
                    let remaining = endTime.timeIntervalSinceNow
                    
                    if remaining <= 0 {
                        self.pause()
                        self.cancelSleepTimer()
                    } else {
                        self.sleepTimerRemaining = remaining
                    }
                }
            }
        }
    }
    
    /// Set sleep timer to end at current chapter
    func setSleepTimerEndOfChapter() {
        cancelSleepTimer()
        
        guard let chapter = currentChapter,
              let position = player?.currentTime().seconds else {
            return
        }
        
        let chapterEnd = chapter.startTime + chapter.duration
        let remaining = chapterEnd - position
        
        if remaining > 0 {
            let endTime = Date().addingTimeInterval(remaining)
            sleepTimerEndTime = endTime
            
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                
                Task { @MainActor in
                    if let endTime = self.sleepTimerEndTime {
                        let remaining = endTime.timeIntervalSinceNow
                        
                        if remaining <= 0 {
                            self.pause()
                            self.cancelSleepTimer()
                        } else {
                            self.sleepTimerRemaining = remaining
                        }
                    }
                }
            }
        }
    }
    
    /// Cancel the active sleep timer
    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndTime = nil
        sleepTimerRemaining = 0
    }
    
    /// Check if sleep timer is active
    var isSleepTimerActive: Bool {
        sleepTimerEndTime != nil
    }
    
    private var currentChapter: Chapter? {
        guard let audiobook = audiobook,
              let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              currentChapterIndex >= 0 && currentChapterIndex < chapters.count else {
            return nil
        }
        return chapters[currentChapterIndex]
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        // Cancel sleep timer
        cancelSleepTimer()
        
        // Remove time observer
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        // Release security-scoped resource access
        if let fileURL = currentFileURL {
            fileURL.stopAccessingSecurityScopedResource()
            currentFileURL = nil
        }
        
        // Clear Now Playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        
        // Clear player
        player = nil
        audiobook = nil
        
        // Remove notification observer
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }
}
