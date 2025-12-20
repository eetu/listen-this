//
//  WatchAudioPlayerService.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import Foundation
import AVFoundation
import SwiftData
import MediaPlayer

/// Watch-specific audio player service with background playback support
@MainActor
@Observable
final class WatchAudioPlayerService {
    
    // MARK: - Properties
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var audiobook: Audiobook?
    private let modelContext: ModelContext
    
    // Observable state
    var isPlaying = false
    var currentPosition: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1.0
    var currentChapterIndex: Int = 0
    var loadError: Error?
    
    // MARK: - Computed Properties
    
    /// Get sorted chapters for the current audiobook
    var sortedChapters: [Chapter] {
        audiobook?.chapters?.sorted(by: { $0.index < $1.index }) ?? []
    }
    
    // MARK: - Initialization
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        setupAudioSession()
    }
    
    deinit {
        // Cleanup is handled by explicit cleanup method
        // deinit cannot be isolated to MainActor
    }
    
    /// Clean up resources before deallocation
    func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // watchOS-specific audio session configuration with AirPods support
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,  // Important for Watch background playback
                options: []
            )
            try audioSession.setActive(true)
            
            // Register for audio interruption notifications (AirPods removal, calls, etc.)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioInterruption),
                name: AVAudioSession.interruptionNotification,
                object: audioSession
            )
            
            // Register for route change notifications (AirPods connect/disconnect)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleRouteChange),
                name: AVAudioSession.routeChangeNotification,
                object: audioSession
            )
        } catch {
            print("❌ [Audio Session] Failed to setup: \(error)")
        }
    }
    
    // MARK: - Audio Interruption Handling
    
    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        Task { @MainActor in
            switch type {
            case .began:
                // Interruption began (call, Siri, AirPods removed, etc.)
                await pause()
                
            case .ended:
                // Interruption ended
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        // System suggests resuming playback
                        await play()
                    }
                }
                
            @unknown default:
                break
            }
        }
    }
    
    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        Task { @MainActor in
            switch reason {
            case .oldDeviceUnavailable:
                // AirPods or headphones were disconnected
                await pause()
                
            case .newDeviceAvailable:
                // AirPods or headphones were connected
                // Don't auto-resume, let user decide
                break
                
            case .categoryChange:
                break
                
            default:
                break
            }
        }
    }
    
    // MARK: - Loading
    
    func load(audiobook: Audiobook) async {
        self.audiobook = audiobook
        loadError = nil

        // Try different sources in priority order
        var fileURL: URL?
        var fileSource: String = "unknown"
        
        // Priority 1: Check the computed expectedCachePath (most reliable on Watch)
        if audiobook.isFileCached,
           let cachedURL = audiobook.cacheFileURL {
            fileURL = cachedURL
            fileSource = "local cache"
        }
        
        // Priority 2: Check CacheEntry path (for legacy support)
        if fileURL == nil,
           let cacheEntry = audiobook.cacheEntry,
           !cacheEntry.filePath.isEmpty,
           !cacheEntry.filePath.hasPrefix("file:///private/var/mobile") {  // Skip iOS paths
            let url = URL(fileURLWithPath: cacheEntry.filePath)
            if FileManager.default.fileExists(atPath: cacheEntry.filePath) {
                fileURL = url
                fileSource = "cache entry"
            } else {
                print("⚠️ [Watch Player] Priority 2: Cache entry exists but file not found at: \(cacheEntry.filePath)")
            }
        }
        
        // Priority 3: Try iCloud container (read-only access if already downloaded)
        if fileURL == nil,
           let iCloudURL = audiobook.iCloudFileURL {
            // Check if file exists (already downloaded by iCloud)
            if FileManager.default.fileExists(atPath: iCloudURL.path) {
                fileURL = iCloudURL
                fileSource = "iCloud container"
            } else {
                print("⚠️ [Watch Player] Priority 3: iCloud file not available on Watch")
            }
        }
        
        // No file available
        guard let finalFileURL = fileURL else {
            print("❌ [Watch Player] ERROR: No file available from any source")
            
            // Provide helpful error message
            if audiobook.iCloudRelativePath != nil {
                loadError = NSError(
                    domain: "WatchPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "File not downloaded. Connect to WiFi to download from iCloud."]
                )
            } else {
                loadError = NSError(
                    domain: "WatchPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "File not available on Watch."]
                )
            }
            return
        }
        
        let localPath = finalFileURL.path
        
        // Verify file is accessible and readable
        let fileManager = FileManager.default
        if !fileManager.isReadableFile(atPath: localPath) {
            print("❌ [Watch Player] ERROR: File is not readable at path: \(localPath)")
            loadError = NSError(domain: "WatchPlayer", code: 3, userInfo: [NSLocalizedDescriptionKey: "File not readable"])
            return
        }
        
        // Get file attributes to verify it's not empty
        do {
            let attributes = try fileManager.attributesOfItem(atPath: localPath)
            if let fileSize = attributes[.size] as? UInt64 {
                _ = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                if fileSize == 0 {
                    print("❌ [Watch Player] ERROR: File is empty")
                    loadError = NSError(domain: "WatchPlayer", code: 4, userInfo: [NSLocalizedDescriptionKey: "File is empty or corrupted"])
                    return
                }
            }
        } catch {
            print("❌ [Watch Player] ERROR: Cannot read file attributes: \(error)")
            loadError = error
            return
        }
        
        let asset = AVURLAsset(url: finalFileURL)
        
        // Wait for asset to load and verify it's playable
        do {
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                print("❌ [Watch Player] ERROR: Asset is not playable")
                loadError = NSError(domain: "WatchPlayer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Audio file format not supported"])
                return
            }
            
            // Try to load tracks to verify it has audio
            let tracks = try await asset.load(.tracks)
            if tracks.isEmpty {
                print("❌ [Watch Player] ERROR: Asset has no tracks")
                loadError = NSError(domain: "WatchPlayer", code: 6, userInfo: [NSLocalizedDescriptionKey: "No audio tracks found in file"])
                return
            }
        } catch {
            print("❌ [Watch Player] ERROR loading asset: \(error)")
            loadError = error
            return
        }
        
        let playerItem = AVPlayerItem(asset: asset)
        
        player = AVPlayer(playerItem: playerItem)
        duration = audiobook.duration
        
        // Restore playback position
        if let session = audiobook.playbackSession {
            currentChapterIndex = session.currentChapter
            currentPosition = session.currentPosition
            
            let time = CMTime(seconds: session.currentPosition, preferredTimescale: 600)
            await player?.seek(to: time)
        }
        
        startPositionTracking()
        setupRemoteCommandCenter()
        updateNowPlayingInfo()
    }
    
    // MARK: - Playback Controls
    
    func play() async {
        player?.play()
        isPlaying = true
        
        // Update Now Playing info
        updateNowPlayingInfo()
        
        // Update last accessed date
        audiobook?.lastAccessedDate = Date()
        try? modelContext.save()
    }
    
    func pause() async {
        player?.pause()
        isPlaying = false
        
        // Update Now Playing info
        updateNowPlayingInfo()
        
        savePlaybackState()
    }
    
    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        player?.rate = Float(rate)
    }
        
    func skip(by seconds: Double) async {
        guard let player = player else { return }
        
        let currentTime = player.currentTime().seconds
        let newTime = max(0, min(duration, currentTime + seconds))
        
        await player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        updateCurrentChapter()
    }
    
    func seek(to position: Double) async {
        guard let player = player else { return }
        
        let clampedPosition = max(0, min(duration, position))
        
        await player.seek(to: CMTime(seconds: clampedPosition, preferredTimescale: 600))
        
        // Immediately update position and chapter
        currentPosition = clampedPosition
        updateCurrentChapter()
    }
    
    // MARK: - Chapter Navigation
    
    func nextChapter() async {
        guard !sortedChapters.isEmpty,
              currentChapterIndex < sortedChapters.count - 1 else { return }
        
        currentChapterIndex += 1
        let nextChapter = sortedChapters[currentChapterIndex]
        
        await player?.seek(to: CMTime(seconds: nextChapter.startTime, preferredTimescale: 600))
        currentPosition = nextChapter.startTime
    }
    
    func previousChapter() async {
        guard !sortedChapters.isEmpty else { return }
        
        // If more than 3 seconds into chapter, restart it
        if currentPosition - sortedChapters[currentChapterIndex].startTime > 3.0 {
            await player?.seek(to: CMTime(seconds: sortedChapters[currentChapterIndex].startTime, preferredTimescale: 600))
            currentPosition = sortedChapters[currentChapterIndex].startTime
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            let prevChapter = sortedChapters[currentChapterIndex]
            await player?.seek(to: CMTime(seconds: prevChapter.startTime, preferredTimescale: 600))
            currentPosition = prevChapter.startTime
        }
    }
    
    func skipToChapter(_ chapter: Chapter) async {
        currentChapterIndex = chapter.index
        await player?.seek(to: CMTime(seconds: chapter.startTime, preferredTimescale: 600))
        
        // Immediately update currentPosition to reflect the seek (before time observer catches up)
        currentPosition = chapter.startTime
    }
    
    // MARK: - Position Tracking
    
    private func startPositionTracking() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.currentPosition = time.seconds
                self.updateCurrentChapter()
                
                // Update Now Playing info periodically
                if Int(time.seconds) % 5 == 0 {
                    self.updateNowPlayingInfo()
                }
                
                // Save state every 5 seconds while playing
                if self.isPlaying && Int(time.seconds) % 5 == 0 {
                    self.savePlaybackState()
                }
            }
        }
    }
    
    // MARK: - Now Playing Info
    
    private var nowPlayingInfo: [String: Any] {
        guard let audiobook = audiobook else { return [:] }
        
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: audiobook.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPosition,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        
        // Add author if available
        if !audiobook.author.isEmpty {
            info[MPMediaItemPropertyArtist] = audiobook.author
        }
        
        // Add chapter information
        if !sortedChapters.isEmpty, currentChapterIndex < sortedChapters.count {
            let currentChapter = sortedChapters[currentChapterIndex]
            info[MPMediaItemPropertyAlbumTitle] = currentChapter.title
        }
        
        return info
    }
    
    private func updateNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    // MARK: - Remote Command Center (AirPods Controls)
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.play()
            }
            return .success
        }
        
        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.pause()
            }
            return .success
        }
        
        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isPlaying {
                    await self.pause()
                } else {
                    await self.play()
                }
            }
            return .success
        }
        
        // Skip forward command (30 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.skip(by: 30)
            }
            return .success
        }
        
        // Skip backward command (15 seconds)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.skip(by: -15)
            }
            return .success
        }
        
        // Next track command (next chapter)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.nextChapter()
            }
            return .success
        }
        
        // Previous track command (previous chapter)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.previousChapter()
            }
            return .success
        }
        
        // Change playback position command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                await self?.seek(to: event.positionTime)
            }
            return .success
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func updateCurrentChapter() {
        guard !sortedChapters.isEmpty else { return }
        
        // Find the current chapter based on position
        // Iterate in reverse to find the latest chapter that has started
        for chapter in sortedChapters.reversed() {
            if currentPosition >= chapter.startTime {
                if currentChapterIndex != chapter.index {
                    currentChapterIndex = chapter.index
                }
                break
            }
        }
    }
    
    // MARK: - State Persistence
    
    private func savePlaybackState() {
        guard let audiobook = audiobook else { return }
        
        // Create or update playback session
        if audiobook.playbackSession == nil {
            let session = PlaybackSession()
            session.audiobook = audiobook
            audiobook.playbackSession = session
            modelContext.insert(session)
        }
        
        audiobook.playbackSession?.currentPosition = currentPosition
        audiobook.playbackSession?.currentChapter = currentChapterIndex
        audiobook.playbackSession?.playbackRate = playbackRate
        audiobook.playbackSession?.lastPlayed = Date()
        audiobook.playbackSession?.progressPercentage = (currentPosition / duration) * 100
        
        do {
            try modelContext.save()
        } catch {
            print("❌ [Watch Player] Failed to save state: \(error)")
        }
    }
}
