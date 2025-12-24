//
//  WatchPlayerView.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 18.12.2025.
//

import SwiftUI
import SwiftData
import AVFoundation
import MediaPlayer
import WatchKit

struct WatchPlayerView: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(WatchConnectivityManager.self) private var connectivity

    @State private var playerService: AudioPlayerService?
    @State private var showingChapterList = false
    @State private var showingContextMenu = false
    @State private var showingDeleteConfirmation = false

    // Volume
    @State private var currentVolume: Float = AVAudioSession.sharedInstance().outputVolume
    @State private var volumeObserver: NSKeyValueObservation?

    // MARK: - Computed

    var sortedChapters: [Chapter]? {
        audiobook.chapters?.sorted(by: { $0.index < $1.index })
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundArtworkView

            VStack(spacing: 0) {
                if audiobook.isFileCached {
                    if let playerService, let sortedChapters {
                        PlayerControlsView(
                            player: playerService,
                            chapters: sortedChapters,
                            showsChapterSkipButtons: false,
                            volume: $currentVolume
                        )
                    }
                } else {
                    downloadPrompt
                        .padding(.bottom, 12)
                }

                Spacer()

                bottomToolbar
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 8)
        }
        .background(VolumeView().opacity(0))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if audiobook.isFileCached {
                    Button { showingContextMenu = true } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $showingChapterList) { chapterListSheet }
        .sheet(isPresented: $showingContextMenu) { contextMenuSheet }
        .alert("Remove Download", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeDownload() }
        } message: {
            Text("This will remove the downloaded file from your Watch.")
        }
        .task {
            observeVolume()
            await loadPlayerIfNeeded()
        }
        .onDisappear {
            Task { await playerService?.pause() }
            volumeObserver?.invalidate()
        }
    }

    // MARK: - Background

    private var backgroundArtworkView: some View {
        Group {
            if let data = audiobook.artworkData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 5)
                    .opacity(0.5)
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            if sortedChapters != nil {
                Button { showingChapterList = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Download Prompt

    private var downloadPrompt: some View {
        VStack(spacing: 8) {
            let active = connectivity.activeTransfers[audiobook.id.uuidString] != nil

            if active {
                ProgressView("Downloading…")
                Button("Cancel", role: .destructive) {
                    connectivity.cancelTransfer(audiobookId: audiobook.id)
                }
            } else if connectivity.isReachable {
                Button {
                    connectivity.requestDownload(audiobookId: audiobook.id)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
            } else {
                Label("iPhone not connected", systemImage: "iphone.slash")
                    .font(.caption)
            }
        }
    }

    // MARK: - Chapter List

    private var chapterListSheet: some View {
        List(sortedChapters ?? []) { chapter in
            Button {
                Task {
                    await playerService?.seek(to: chapter.startTime)
                    showingChapterList = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chapter \(chapter.index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(chapter.title)
                }
            }
        }
        .navigationTitle("Chapters")
        .focusable(true)
    }

    // MARK: - Context Menu

    private var contextMenuSheet: some View {
        List {
            if let playerService {
                Section {
                    NavigationLink("Playback Speed") {
                        playbackSpeedPicker(playerService)
                    }
                }
            }

            Section {
                Button("Remove Download", role: .destructive) {
                    showingContextMenu = false
                    showingDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("Options")
    }

    // MARK: - Playback Speed

    private func playbackSpeedPicker(_ player: AudioPlayerService) -> some View {
        List([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
            Button {
                player.setPlaybackRate(rate)
                showingContextMenu = false
            } label: {
                HStack {
                    Text("\(rate, specifier: "%.2f")x")
                    Spacer()
                    if abs(player.playbackRate - rate) < 0.01 {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Playback Speed")
    }

    // MARK: - Helpers

    private func loadPlayerIfNeeded() async {
        guard playerService == nil, audiobook.isFileCached else { return }
        let service = AudioPlayerService(modelContext: modelContext)
        playerService = service
        await service.load(audiobook: audiobook)
    }

    private func observeVolume() {
        let session = AVAudioSession.sharedInstance()
        volumeObserver = session.observe(\.outputVolume) { session, _ in
            DispatchQueue.main.async {
                currentVolume = session.outputVolume
            }
        }
    }

    private func removeDownload() {
        if let entry = audiobook.cacheEntry {
            try? FileManager.default.removeItem(atPath: entry.filePath)
            modelContext.delete(entry)
        }
        audiobook.cacheEntry = nil
        try? modelContext.save()
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Volume View

/// Wrapper for WKInterfaceVolumeControl to enable digital crown volume control
struct VolumeView: WKInterfaceObjectRepresentable {
    typealias WKInterfaceObjectType = WKInterfaceVolumeControl

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let view = WKInterfaceVolumeControl(origin: .local)

        // Keep the volume control focused to enable digital crown rotation
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak view] timer in
            if let view = view {
                view.focus()
            } else {
                timer.invalidate()
            }
        }

        // Initial focus
        DispatchQueue.main.async {
            view.focus()
        }

        return view
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
        // No updates needed
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
