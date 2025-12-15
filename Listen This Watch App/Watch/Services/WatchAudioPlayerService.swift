//
//  WatchAudioPlayerService.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import Foundation
import AVFoundation
import SwiftData

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
            
            // watchOS-specific audio session configuration
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,  // Important for Watch background playback
                options: []
            )
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }
    
    // MARK: - Loading
    
    func load(audiobook: Audiobook) async {
        self.audiobook = audiobook
        
        guard audiobook.isCached,
              let localPath = audiobook.localFilePath else {
            print("Audiobook not cached locally")
            return
        }
        
        let url = URL(fileURLWithPath: localPath)
        let asset = AVURLAsset(url: url)
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
    }
    
    // MARK: - Playback Controls
    
    func play() async {
        player?.play()
        isPlaying = true
        
        // Update last accessed date
        audiobook?.lastAccessedDate = Date()
        try? modelContext.save()
    }
    
    func pause() async {
        player?.pause()
        isPlaying = false
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
    
    // MARK: - Chapter Navigation
    
    func nextChapter() async {
        guard let chapters = audiobook?.chapters,
              currentChapterIndex < chapters.count - 1 else { return }
        
        currentChapterIndex += 1
        let nextChapter = chapters[currentChapterIndex]
        
        await player?.seek(to: CMTime(seconds: nextChapter.startTime, preferredTimescale: 600))
    }
    
    func previousChapter() async {
        guard let chapters = audiobook?.chapters else { return }
        
        // If more than 3 seconds into chapter, restart it
        if currentPosition - chapters[currentChapterIndex].startTime > 3.0 {
            await player?.seek(to: CMTime(seconds: chapters[currentChapterIndex].startTime, preferredTimescale: 600))
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            let prevChapter = chapters[currentChapterIndex]
            await player?.seek(to: CMTime(seconds: prevChapter.startTime, preferredTimescale: 600))
        }
    }
    
    func skipToChapter(_ chapter: Chapter) async {
        currentChapterIndex = chapter.index
        await player?.seek(to: CMTime(seconds: chapter.startTime, preferredTimescale: 600))
    }
    
    // MARK: - Position Tracking
    
    private func startPositionTracking() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentPosition = time.seconds
                self?.updateCurrentChapter()
            }
        }
    }
    
    private func updateCurrentChapter() {
        guard let chapters = audiobook?.chapters else { return }
        
        for (index, chapter) in chapters.enumerated().reversed() {
            if currentPosition >= chapter.startTime {
                currentChapterIndex = index
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
        
        try? modelContext.save()
    }
}
