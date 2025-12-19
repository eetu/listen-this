//
//  WatchPlayerView.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import SwiftUI
import SwiftData
import AVFoundation

struct WatchPlayerView: View {
    let audiobook: Audiobook
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchConnectivityManager.self) private var connectivity
    
    @State private var player: WatchAudioPlayerService?
    @State private var showingChapterList = false
    @State private var showingContextMenu = false
    @State private var showingDeleteConfirmation = false
    
    // MARK: - Computed Properties
        
    /// Get sorted chapters for the audiobook
    var sortedChapters: [Chapter] {
        audiobook.chapters?.sorted(by: { $0.index < $1.index }) ?? []
    }
    
    /// Get current chapter from player
    var currentChapter: Chapter? {
        guard let player = player,
              !sortedChapters.isEmpty,
              player.currentChapterIndex >= 0,
              player.currentChapterIndex < sortedChapters.count else {
            return nil
        }
        return sortedChapters[player.currentChapterIndex]
    }
    
    var body: some View {
        ZStack {
            // Background blurred artwork
            backgroundArtworkView
            
            // Main content
            VStack(spacing: 0) {                
                // Check if file is available
                if audiobook.isFileCached {
                    if let player = player {
                        // Player controls
                        playerControlsView(player: player)
                            .padding(.bottom, 12)
                    } else {
                        ProgressView("Loading...")
                    }
                } else {
                    // Download prompt
                    downloadPromptView
                        .padding(.bottom, 12)
                }
                
                Spacer()
                
                // Bottom toolbar
                bottomToolbarView
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 8)
        }
        .focusable(true) // Make view focusable for Digital Crown
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if audiobook.isFileCached {
                    Button {
                        showingContextMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showingChapterList) {
            chapterListSheet
        }
        .sheet(isPresented: $showingContextMenu) {
            contextMenuSheet
        }
        .alert("Remove Download", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                removeDownload()
            }
        } message: {
            Text("This will remove the downloaded file from your Watch. You can re-download it later from your iPhone.")
        }
        .task {
            if audiobook.isFileCached {
                await loadPlayer()
            }
        }
        .onDisappear {
            player?.cleanup()
        }
    }
    
    // MARK: - Background Artwork
    
    private var backgroundArtworkView: some View {
        Group {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .blur(radius: 10)
                    .opacity(0.5)
            }
        }
    }
        
    // MARK: - Bottom Toolbar
    
    private var bottomToolbarView: some View {
        HStack {
            // Chapter list button
            if !sortedChapters.isEmpty {
                Button {
                    showingChapterList = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Player Controls
    
    @ViewBuilder
    private func playerControlsView(player: WatchAudioPlayerService) -> some View {
        VStack(spacing: 4) {
            // Progress bar (chapter-based)
            VStack(spacing: 2) {
                // Force observation of player properties
                let _ = player.currentPosition  // Force observation
                let _ = player.duration  // Force observation
                let _ = player.currentChapterIndex  // Force observation
                
                let chapterProgress = calculateChapterProgress(player: player)
                
                ProgressView(
                    value: chapterProgress.position,
                    total: max(chapterProgress.duration, 0.01) // Prevent division by zero
                )
                .controlSize(.mini)
                .animation(.linear(duration: 0.5), value: chapterProgress.position)
                
                HStack {
                    Text(formatTime(chapterProgress.position))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text(formatTime(chapterProgress.duration))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }.padding(.top, 32)
            
            // Current chapter (compact)
            if let currentChapter = currentChapter {
                Text(currentChapter.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
            
            // Playback controls
            HStack(spacing: 20) {
                // Skip backward 15s
                Button {
                    Task {
                        await player.skip(by: -15)
                    }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                
                // Play/Pause button
                Button {
                    Task {
                        if player.isPlaying {
                            await player.pause()
                        } else {
                            await player.play()
                        }
                    }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 60))
                }
                .buttonStyle(.plain)
                
                // Skip forward 30s
                Button {
                    Task {
                        await player.skip(by: 30)
                    }
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
            }
            
            // Error display
            if let error = player.loadError {
                Text(error.localizedDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }
    
    // MARK: - Download Prompt
    
    private var downloadPromptView: some View {
        VStack(spacing: 8) {
            // Check if there's an active transfer
            let hasActiveTransfer = connectivity.activeTransfers[audiobook.id.uuidString] != nil
            
            if hasActiveTransfer {
                // Show transfer in progress with cancel button
                VStack(spacing: 12) {
                    // Transfer indicator
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.large)
                        
                        Text("Downloading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Cancel button
                    Button(role: .destructive) {
                        connectivity.cancelTransfer(audiobookId: audiobook.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Cancel")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else if connectivity.isReachable {
                Button {
                    connectivity.requestDownload(audiobookId: audiobook.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                        Text("Download")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "iphone.slash")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("iPhone not connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Chapter List Sheet
    
    private var chapterListSheet: some View {
        NavigationStack {
            List {
                ForEach(sortedChapters) { chapter in
                    Button {
                        Task {
                            await player?.skipToChapter(chapter)
                            showingChapterList = false
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chapter \(chapter.index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(chapter.title)
                                .font(.body)
                            Text(formatTime(chapter.startTime))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(
                        player?.currentChapterIndex == chapter.index ? 
                            Color.accentColor.opacity(0.2) : Color.clear
                    )
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Context Menu Sheet
    
    private var contextMenuSheet: some View {
        NavigationStack {
            List {
                // Actions section
                Section {
                    // Playback speed (if player exists)
                    if let player = player {
                        NavigationLink {
                            playbackSpeedPicker(player: player)
                        } label: {
                            HStack {
                                Label("Playback Speed", systemImage: "speedometer")
                                Spacer()
                                Text("\(String(format: "%.2f", player.playbackRate))x")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                // Danger zone
                Section {
                    Button(role: .destructive) {
                        showingContextMenu = false
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } footer: {
                    Text("This will remove the downloaded file from your Watch.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Playback Speed Picker
    
    @ViewBuilder
    private func playbackSpeedPicker(player: WatchAudioPlayerService) -> some View {
        List {
            Button {
                Task { 
                    await player.setPlaybackRate(0.75)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("0.75x")
                    Spacer()
                    if abs(player.playbackRate - 0.75) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Button {
                Task { 
                    await player.setPlaybackRate(1.0)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("1.0x")
                    Spacer()
                    if abs(player.playbackRate - 1.0) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Button {
                Task { 
                    await player.setPlaybackRate(1.25)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("1.25x")
                    Spacer()
                    if abs(player.playbackRate - 1.25) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Button {
                Task { 
                    await player.setPlaybackRate(1.5)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("1.5x")
                    Spacer()
                    if abs(player.playbackRate - 1.5) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Button {
                Task { 
                    await player.setPlaybackRate(1.75)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("1.75x")
                    Spacer()
                    if abs(player.playbackRate - 1.75) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Button {
                Task { 
                    await player.setPlaybackRate(2.0)
                    showingContextMenu = false
                }
            } label: {
                HStack {
                    Text("2.0x")
                    Spacer()
                    if abs(player.playbackRate - 2.0) < 0.01 {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("Playback Speed")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Helper Methods
    
    private func calculateChapterProgress(player: WatchAudioPlayerService) -> (position: Double, duration: Double) {
        // Get current chapter
        guard !sortedChapters.isEmpty,
              player.currentChapterIndex >= 0,
              player.currentChapterIndex < sortedChapters.count else {
            // Fallback to total duration if no chapters
            let result = (position: player.currentPosition, duration: player.duration)
            print("📊 [Progress] No chapters - Total: \(Int(result.position))s / \(Int(result.duration))s")
            return result
        }
        
        let currentChapter = sortedChapters[player.currentChapterIndex]
        
        // Calculate position within current chapter
        let chapterPosition = max(0, player.currentPosition - currentChapter.startTime)
        let chapterDuration = currentChapter.duration
        
        let result = (position: chapterPosition, duration: chapterDuration)
        
        // Debug logging (only log every 5 seconds to avoid spam)
        if Int(player.currentPosition) % 5 == 0 {
            print("📊 [Progress] Chapter \(player.currentChapterIndex + 1): \(Int(result.position))s / \(Int(result.duration))s")
            print("   Absolute position: \(Int(player.currentPosition))s, Chapter start: \(Int(currentChapter.startTime))s")
        }
        
        return result
    }
    
    private func loadPlayer() async {
        let newPlayer = WatchAudioPlayerService(modelContext: modelContext)
        await newPlayer.load(audiobook: audiobook)
        player = newPlayer
    }
    
    private func removeDownload() {
        // Stop and cleanup player
        player?.cleanup()
        player = nil
        
        // Remove the cache entry and file
        if let cacheEntry = audiobook.cacheEntry {
            // Delete file
            let fileURL = URL(fileURLWithPath: cacheEntry.filePath)
            try? FileManager.default.removeItem(at: fileURL)
            
            // Remove cache entry
            modelContext.delete(cacheEntry)
        }
        
        // Clear audiobook cache reference
        audiobook.cacheEntry = nil
        // DON'T clear localFilename - it's needed for future transfers!
        // audiobook.localFilename = nil
        
        // Save changes
        try? modelContext.save()
        
        print("🗑️ [Watch Player] Removed download for: \(audiobook.title)")
        print("   Kept localFilename: \(audiobook.localFilename ?? "nil")")
    }
    
    
    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Audiobook.self, configurations: config)
    let context = ModelContext(container)
    
    let audiobook = Audiobook(
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        narrator: "Andy Serkis",
        duration: 36000,
        fileSize: 500_000_000
    )
    context.insert(audiobook)
    
    return NavigationStack {
        WatchPlayerView(audiobook: audiobook)
            .modelContainer(container)
            .environment(WatchConnectivityManager.shared)
    }
}
