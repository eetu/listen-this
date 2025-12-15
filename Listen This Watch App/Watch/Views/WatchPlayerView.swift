//
//  WatchPlayerView.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI

struct WatchPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let audiobook: Audiobook
    @State private var playerService: WatchAudioPlayerService?
    @State private var showingChapters = false
    @State private var showingPlaybackSpeed = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Artwork
                    if let artworkData = audiobook.artworkData,
                       let uiImage = UIImage(data: artworkData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Chapter info
                    if let service = playerService,
                       let chapters = audiobook.chapters,
                       service.currentChapterIndex < chapters.count {
                        let currentChapter = chapters[service.currentChapterIndex]
                        
                        VStack(spacing: 2) {
                            Text(currentChapter.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            
                            Text("Chapter \(service.currentChapterIndex + 1) of \(chapters.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Progress
                    if let service = playerService,
                       let chapters = audiobook.chapters,
                       service.currentChapterIndex < chapters.count {
                        let currentChapter = chapters[service.currentChapterIndex]
                        let chapterProgress = service.currentPosition - currentChapter.startTime
                        
                        VStack(spacing: 4) {
                            HStack {
                                Text(formatTime(chapterProgress))
                                    .font(.caption2)
                                    .monospacedDigit()
                                
                                Spacer()
                                
                                Text(formatTime(currentChapter.duration))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            
                            ProgressView(value: chapterProgress, total: currentChapter.duration)
                        }
                        .padding(.horizontal)
                    }
                    
                    // Playback controls
                    if let service = playerService {
                        HStack(spacing: 20) {
                            // Previous chapter
                            Button {
                                Task {
                                    await service.previousChapter()
                                }
                            } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .buttonStyle(.plain)
                            
                            // Skip back 15s
                            Button {
                                Task {
                                    await service.skip(by: -15)
                                }
                            } label: {
                                Image(systemName: "gobackward.15")
                            }
                            .buttonStyle(.plain)
                            
                            // Play/Pause
                            Button {
                                Task {
                                    if service.isPlaying {
                                        await service.pause()
                                    } else {
                                        await service.play()
                                    }
                                }
                            } label: {
                                Image(systemName: service.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 44))
                            }
                            .buttonStyle(.plain)
                            
                            // Skip forward 30s
                            Button {
                                Task {
                                    await service.skip(by: 30)
                                }
                            } label: {
                                Image(systemName: "goforward.30")
                            }
                            .buttonStyle(.plain)
                            
                            // Next chapter
                            Button {
                                Task {
                                    await service.nextChapter()
                                }
                            } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                    }
                    
                    // Additional controls
                    HStack(spacing: 16) {
                        // Playback speed
                        if let service = playerService {
                            Button {
                                showingPlaybackSpeed = true
                            } label: {
                                Label(String(format: "%.2f×", service.playbackRate), systemImage: "gauge")
                                    .font(.caption)
                            }
                        }
                        
                        // Chapters
                        Button {
                            showingChapters = true
                        } label: {
                            Label("Chapters", systemImage: "list.bullet")
                                .font(.caption)
                        }
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingChapters) {
                if let chapters = audiobook.chapters {
                    WatchChapterListView(
                        chapters: chapters,
                        currentChapterIndex: playerService?.currentChapterIndex ?? 0
                    ) { chapter in
                        Task {
                            await playerService?.skipToChapter(chapter)
                        }
                        showingChapters = false
                    }
                }
            }
            .sheet(isPresented: $showingPlaybackSpeed) {
                NavigationStack {
                    List {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { (speed: Double) in
                            Button {
                                Task {
                                    await playerService?.setPlaybackRate(speed)
                                }
                                showingPlaybackSpeed = false
                            } label: {
                                HStack {
                                    Text(String(format: "%.2f×", speed))
                                    Spacer()
                                    if let service = playerService,
                                       abs(service.playbackRate - speed) < 0.01 {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Speed")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingPlaybackSpeed = false
                            }
                        }
                    }
                }
            }
        }
        .task {
            // Initialize player service
            let service = WatchAudioPlayerService(modelContext: modelContext)
            await service.load(audiobook: audiobook)
            playerService = service
        }
        .onDisappear {
            // Cleanup
            Task {
                await playerService?.pause()
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

#Preview {
    let audiobook = Audiobook(
        title: "Sample Audiobook",
        author: "John Doe",
        duration: 36000,
        isCached: true,
        chapterCount: 25
    )
    
    WatchPlayerView(audiobook: audiobook)
}
