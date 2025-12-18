//
//  PlayerView.swift
//  listen this
//
//  Created on 13.12.2025.
//

import SwiftUI
import SwiftData

struct PlayerView: View {
    let audiobook: Audiobook
    
    @Environment(\.modelContext) private var modelContext
    @State private var playerService: AudioPlayerService?
    @State private var showingChapters = false
    @State private var showingSpeedPicker = false
    @State private var showingSleepTimer = false
    @State private var loadError: AudiobookError?
    
    var formattedPosition: String {
        formatTime(currentChapterPosition)
    }
    
    var formattedDuration: String {
        formatTime(currentChapterDuration)
    }
    
    var currentChapter: Chapter? {
        guard let chapters = audiobook.chapters?.sorted(by: { $0.index < $1.index }),
              let index = playerService?.currentChapterIndex,
              index >= 0 && index < chapters.count else {
            return nil
        }
        return chapters[index]
    }
    
    var currentChapterPosition: Double {
        guard let chapter = currentChapter,
              let position = playerService?.currentPosition else {
            return 0
        }
        // Position within the current chapter
        return max(0, position - chapter.startTime)
    }
    
    var currentChapterDuration: Double {
        currentChapter?.duration ?? audiobook.duration
    }
    
    var currentChapterIndex: Int {
        playerService?.currentChapterIndex ?? (audiobook.playbackSession?.currentChapter ?? 0)
    }
    
    var isPlaying: Bool {
        playerService?.isPlaying ?? false
    }
    
    var body: some View {
            VStack(spacing: 24) {
                // Artwork
                artworkView
                
                // Book Info
                bookInfoSection
                
                Spacer()

                // Progress Slider
                progressSection
                
                // Playback Controls
                playbackControlsSection
                
            }
            .padding()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Bottom toolbar items
            ToolbarItemGroup(placement: .bottomBar) {
                // Chapters button
                Button {
                    showingChapters = true
                } label: {
                    Label("Chapters", systemImage: "list.bullet")
                }
                
                Spacer()
                
                // Playback Speed
                Button {
                    showingSpeedPicker = true
                } label: {
                    let currentRate = playerService?.playbackRate ?? 1.0
                    if abs(currentRate - 1.0) < 0.01 {
                        // Show just the icon when at 1.0x
                        Label("Speed", systemImage: "gauge.with.dots.needle.67percent")
                    } else {
                        // Show rate when it's not 1.0x
                        Label("\(currentRate, specifier: "%.1f")x", 
                              systemImage: "gauge.with.dots.needle.67percent")
                    }
                }
                
                Spacer()
                
                // Sleep Timer
                Button {
                    showingSleepTimer = true
                } label: {
                    Label("Sleep Timer", systemImage: "moon")
                }
            }
        }
        .sheet(isPresented: $showingChapters) {
            ChaptersListView(audiobook: audiobook, playerService: playerService)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingSpeedPicker) {
            PlaybackSpeedPickerView(playerService: playerService)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSleepTimer) {
            SleepTimerView(playerService: playerService)
                .presentationDetents([.height(playerService?.isSleepTimerActive == true ? 400 : 330)])
                .presentationDragIndicator(.visible)
        }
        .alert("Playback Error", isPresented: .constant(loadError != nil)) {
            Button("OK") {
                loadError = nil
            }
        } message: {
            if let error = loadError {
                Text(error.userMessage)
            }
        }
        .task {
            await loadAudiobook()
        }
        .onDisappear {
            playerService?.pause()
        }
    }
    
    // MARK: - Artwork View
    
    private var artworkView: some View {
        Group {
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.tertiary).aspectRatio(contentMode: .fit)
                    
                    Image(systemName: "book.closed")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 10)
    }
    
    // MARK: - Book Info Section
    
    private var bookInfoSection: some View {
        VStack(spacing: 8) {
            // Chapter title as main heading
            if let chapter = currentChapter {
                Text(chapter.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                
                Text("Chapter \(chapter.index + 1) of \(audiobook.chapterCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(audiobook.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Progress Section
    
    private var progressSection: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { 
                        currentChapterPosition
                    },
                    set: { newValue in
                        // Convert chapter position back to absolute position
                        guard let chapter = currentChapter else { return }
                        let absolutePosition = chapter.startTime + newValue
                        Task {
                            await playerService?.seek(to: absolutePosition)
                        }
                    }
                ),
                in: 0...max(currentChapterDuration, 1)
            )
            .tint(.accentColor)
            
            HStack {
                Text(formattedPosition)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text(formattedDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
    
    // MARK: - Playback Controls
    
    private var playbackControlsSection: some View {
        HStack(spacing: 40) {
            // Previous Chapter
            Button {
                Task {
                    await playerService?.previousChapter()
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
            }
            .disabled(currentChapterIndex == 0)
            
            // Skip Back 15s
            Button {
                Task {
                    await playerService?.skipBackward()
                }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30))
            }
            
            // Play/Pause
            Button {
                playerService?.togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
            }
            
            // Skip Forward 30s
            Button {
                Task {
                    await playerService?.skipForward()
                }
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 30))
            }
            
            // Next Chapter
            Button {
                Task {
                    await playerService?.nextChapter()
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
            }
            .disabled(currentChapterIndex >= audiobook.chapterCount - 1)
        }
        .foregroundStyle(.primary)
    }
    
    // MARK: - Helper Methods
    
    private func loadAudiobook() async {
        // Initialize player service if needed
        if playerService == nil {
            playerService = AudioPlayerService(modelContext: modelContext)
        }
        
        // Load the audiobook
        do {
            try await playerService?.loadAudiobook(audiobook)
        } catch let error as AudiobookError {
            loadError = error
        } catch {
            loadError = .unknown(error)
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

// MARK: - Chapters List View

struct ChaptersListView: View {
    let audiobook: Audiobook
    let playerService: AudioPlayerService?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if let chapters = audiobook.chapters, !chapters.isEmpty {
                    ForEach(chapters.sorted(by: { $0.index < $1.index })) { chapter in
                        Button {
                            Task {
                                await playerService?.jumpToChapter(at: chapter.index)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapter.title)
                                        .font(.headline)
                                    
                                    Text("Chapter \(chapter.index + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                // Show checkmark if this is current chapter
                                if chapter.index == (playerService?.currentChapterIndex ?? 0) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Chapters",
                        systemImage: "list.bullet",
                        description: Text("This audiobook doesn't have chapter information")
                    )
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Playback Speed Picker View

struct PlaybackSpeedPickerView: View {
    let playerService: AudioPlayerService?
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedSpeed: Double
    
    // Common speed presets
    let speedPresets: [Double] = [0.5, 1.0, 1.2, 1.5, 1.7, 2.0]
    
    init(playerService: AudioPlayerService?) {
        self.playerService = playerService
        _selectedSpeed = State(initialValue: playerService?.playbackRate ?? 1.0)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack(spacing: 12) {
                Text("Speed")
                    .font(.system(size: 20))
                    .monospacedDigit()
                Spacer()
                Text("\(selectedSpeed, specifier: "%.1f")x")
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.top)
            .padding(.horizontal)
            
            // Slider
            VStack(spacing: 12) {
                HStack {
                    Text("0.5")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: $selectedSpeed,
                        in: 0.5...3.0,
                        step: 0.05
                    )
                    .onChange(of: selectedSpeed) { _, newValue in
                        playerService?.setPlaybackRate(newValue)
                    }
                    .tint(.accentColor)
                    
                    Text("3.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
                        
            // Preset buttons
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    ForEach(speedPresets, id: \.self) { speed in
                        Button {
                            withAnimation(.snappy) {
                                selectedSpeed = speed
                                playerService?.setPlaybackRate(speed)
                            }
                        } label: {
                            HStack {
                                Text("\(speed, specifier: "%.1f")")
                                    .font(.body.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(abs(selectedSpeed - speed) < 0.05 ? Color.accentColor : Color(.systemGray5))
                            )
                            .foregroundStyle(abs(selectedSpeed - speed) < 0.05 ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Sleep Timer View

struct SleepTimerView: View {
    let playerService: AudioPlayerService?
    @Environment(\.dismiss) private var dismiss
    
    // Timer presets in minutes
    let timerPresets: [Int] = [5, 10, 15, 30, 45, 60]
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Text("Sleep Timer")
                    .font(.headline)
                
                Spacer()
                
                if playerService?.isSleepTimerActive == true {
                    Text(formattedTimeRemaining)
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            .padding(.top)
            .padding(.horizontal)
            
            // Timer preset buttons
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(timerPresets, id: \.self) { minutes in
                    Button {
                        playerService?.setSleepTimer(minutes: minutes)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(minutes)")
                                .font(.title2.weight(.semibold))
                            Text(minutes == 1 ? "minute" : "minutes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
                        
            // Special options
            VStack(spacing: 12) {
                Button {
                    playerService?.setSleepTimerEndOfChapter()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "book.closed")
                        Text("End of Chapter")
                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray5))
                    )
                }
                .buttonStyle(.plain)
                
                if playerService?.isSleepTimerActive == true {
                    Button(role: .destructive) {
                        playerService?.cancelSleepTimer()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("Cancel Timer")
                            Spacer()
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red.opacity(0.1))
                        )
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            Spacer()
        }
    }
    
    private var formattedTimeRemaining: String {
        let remaining = playerService?.sleepTimerRemaining ?? 0
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    NavigationStack {
        PlayerView(audiobook: Audiobook(
            title: "Sample Audiobook",
            author: "John Doe",
            narrator: "Jane Smith",
            duration: 36000,
        ))
    }
    .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self])
}
