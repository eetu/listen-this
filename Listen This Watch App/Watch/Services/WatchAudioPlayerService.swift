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
    var loadError: Error?
    
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
        loadError = nil

        print("🎵 [Watch Player] Loading audiobook: \(audiobook.title)")
        print("🎵 [Watch Player] Expected cache path: \(audiobook.expectedCachePath)")
        print("🎵 [Watch Player] Has cache entry: \(audiobook.cacheEntry != nil)")
        print("🎵 [Watch Player] iCloud path: \(audiobook.iCloudRelativePath ?? "none")")

        // Try different sources in priority order
        var fileURL: URL?
        var fileSource: String = "unknown"
        
        // Priority 1: Check the computed expectedCachePath (most reliable on Watch)
        if audiobook.isFileCached,
           let cachedURL = audiobook.cacheFileURL {
            print("✅ [Watch Player] Priority 1: Found file at expected cache path")
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
                print("✅ [Watch Player] Priority 2: Found file via cache entry")
                fileURL = url
                fileSource = "cache entry"
            } else {
                print("⚠️ [Watch Player] Priority 2: Cache entry exists but file not found at: \(cacheEntry.filePath)")
            }
        }
        
        // Priority 3: Try iCloud container (read-only access if already downloaded)
        if fileURL == nil,
           let iCloudURL = audiobook.iCloudFileURL {
            print("☁️ [Watch Player] Priority 3: Checking iCloud container...")
            
            // Check if file exists (already downloaded by iCloud)
            if FileManager.default.fileExists(atPath: iCloudURL.path) {
                print("✅ [Watch Player] Priority 3: Found file in iCloud container")
                fileURL = iCloudURL
                fileSource = "iCloud container"
            } else {
                print("⚠️ [Watch Player] Priority 3: iCloud file not available on Watch")
                print("💡 [Watch Player] Use WatchDownloadManager to download from iCloud on WiFi")
            }
        }
        
        // No file available
        guard let finalFileURL = fileURL else {
            print("❌ [Watch Player] ERROR: No file available from any source")
            
            // Provide helpful error message
            if audiobook.iCloudRelativePath != nil {
                print("💡 [Watch Player] This file needs to be downloaded via WiFi")
                print("💡 [Watch Player] Use WatchDownloadManager to queue download")
                loadError = NSError(
                    domain: "WatchPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "File not downloaded. Connect to WiFi to download from iCloud."]
                )
            } else {
                print("💡 [Watch Player] No file location configured")
                loadError = NSError(
                    domain: "WatchPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "File not available on Watch."]
                )
            }
            return
        }
        
        print("✅ [Watch Player] Using file from: \(fileSource)")
        print("✅ [Watch Player] File path: \(finalFileURL.path)")
        
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
                let sizeString = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                print("📦 [Watch Player] File size: \(sizeString)")
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
            
            print("✅ [Watch Player] Asset is playable with \(tracks.count) track(s)")
        } catch {
            print("❌ [Watch Player] ERROR loading asset: \(error)")
            loadError = error
            return
        }
        
        let playerItem = AVPlayerItem(asset: asset)
        
        player = AVPlayer(playerItem: playerItem)
        duration = audiobook.duration
        
        print("🎵 [Watch Player] Duration: \(Int(duration))s (\(Int(duration/60))min)")
        
        // Restore playback position
        if let session = audiobook.playbackSession {
            currentChapterIndex = session.currentChapter
            currentPosition = session.currentPosition
            
            print("📍 [Watch Player] Restoring position: \(Int(session.currentPosition))s at chapter \(session.currentChapter)")
            
            let time = CMTime(seconds: session.currentPosition, preferredTimescale: 600)
            await player?.seek(to: time)
        } else {
            print("📍 [Watch Player] No playback session found, starting from beginning")
        }
        
        startPositionTracking()
        print("✅ [Watch Player] Player initialized successfully")
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
                guard let self = self else { return }
                self.currentPosition = time.seconds
                self.updateCurrentChapter()
                
                // Save state every 5 seconds while playing
                if self.isPlaying && Int(time.seconds) % 5 == 0 {
                    self.savePlaybackState()
                    print("💾 [Watch Player] Auto-saved progress: \(Int(time.seconds))s")
                }
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
        
        print("💾 [Watch Player] Saving state - Position: \(Int(currentPosition))s, Chapter: \(currentChapterIndex)")
        
        // Create or update playback session
        if audiobook.playbackSession == nil {
            let session = PlaybackSession()
            session.audiobook = audiobook
            audiobook.playbackSession = session
            modelContext.insert(session)
            print("💾 [Watch Player] Created new playback session")
        }
        
        audiobook.playbackSession?.currentPosition = currentPosition
        audiobook.playbackSession?.currentChapter = currentChapterIndex
        audiobook.playbackSession?.playbackRate = playbackRate
        audiobook.playbackSession?.lastPlayed = Date()
        audiobook.playbackSession?.progressPercentage = (currentPosition / duration) * 100
        
        do {
            try modelContext.save()
            print("✅ [Watch Player] State saved successfully - Progress: \(Int((currentPosition / duration) * 100))%")
        } catch {
            print("❌ [Watch Player] Failed to save state: \(error)")
        }
    }
}
