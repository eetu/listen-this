//
//  WatchPlayerView.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import SwiftUI
import SwiftData

struct WatchPlayerView: View {
    let audiobook: Audiobook
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchConnectivityManager.self) private var connectivity
    
    @State private var player: WatchAudioPlayerService?
    @State private var showingDownloadPrompt = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Artwork
                artworkView
                
                // Book info
                bookInfoView
                
                // Check if file is available
                if audiobook.isFileCached {
                    // Player controls
                    if let player = player {
                        playerControlsView(player: player)
                    } else {
                        ProgressView("Loading...")
                    }
                } else {
                    // Download prompt
                    downloadPromptView
                }
            }
            .padding()
        }
        .navigationTitle(audiobook.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if audiobook.isFileCached {
                await loadPlayer()
            }
        }
        .onDisappear {
            player?.cleanup()
        }
    }
    
    // MARK: - Artwork
    
    private var artworkView: some View {
        Group {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 120)
                    .overlay {
                        Image(systemName: "book.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
    
    // MARK: - Book Info
    
    private var bookInfoView: some View {
        VStack(spacing: 4) {
            Text(audiobook.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            
            Text(audiobook.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let narrator = audiobook.narrator {
                Text("Narrated by \(narrator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Duration
            Text(formatDuration(audiobook.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
    
    // MARK: - Player Controls
    
    @ViewBuilder
    private func playerControlsView(player: WatchAudioPlayerService) -> some View {
        VStack(spacing: 16) {
            // Progress bar
            VStack(spacing: 4) {
                ProgressView(
                    value: player.currentPosition,
                    total: player.duration
                )
                
                HStack {
                    Text(formatTime(player.currentPosition))
                        .font(.caption2)
                    Spacer()
                    Text(formatTime(player.duration))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            
            // Current chapter
            if let chapters = audiobook.chapters,
               !chapters.isEmpty,
               player.currentChapterIndex < chapters.count {
                Text("Chapter \(player.currentChapterIndex + 1): \(chapters[player.currentChapterIndex].title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            // Playback controls
            HStack(spacing: 20) {
                // Previous chapter
                Button {
                    Task {
                        await player.previousChapter()
                    }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .disabled(!player.isPlaying && player.currentPosition == 0)
                
                // Skip backward 15s
                Button {
                    Task {
                        await player.skip(by: -15)
                    }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                }
                
                // Play/Pause
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
                        .font(.system(size: 50))
                }
                .buttonStyle(.plain)
                
                // Skip forward 30s
                Button {
                    Task {
                        await player.skip(by: 30)
                    }
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                }
                
                // Next chapter
                Button {
                    Task {
                        await player.nextChapter()
                    }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .disabled(audiobook.chapters?.isEmpty ?? true)
            }
            
            // Error display
            if let error = player.loadError {
                Text("Error: \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
    }
    
    // MARK: - Download Prompt
    
    private var downloadPromptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            
            Text("Not Downloaded")
                .font(.headline)
            
            Text("This audiobook needs to be transferred from your iPhone to play on Watch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if connectivity.isReachable {
                Button {
                    connectivity.requestDownload(audiobookId: audiobook.id)
                } label: {
                    Label("Download from iPhone", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            } else {
                Label("iPhone not connected", systemImage: "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
                
                Text("Connect your iPhone to transfer this book")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
    
    // MARK: - Helper Methods
    
    private func loadPlayer() async {
        let newPlayer = WatchAudioPlayerService(modelContext: modelContext)
        await newPlayer.load(audiobook: audiobook)
        player = newPlayer
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
