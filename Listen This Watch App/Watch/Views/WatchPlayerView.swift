//
//  WatchPlayerView.swift
//  Listen This Watch App
//

import AVFoundation
import MediaPlayer
import SwiftData
import SwiftUI
import WatchKit

struct WatchPlayerView: View {
    let audiobook: Audiobook

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(WatchConnectivityManager.self) private var connectivity

    @State private var playerService: AudioPlayerService?
    @State private var isLoadingPlayer = false
    @State private var showingChapterList = false
    @State private var showingContextMenu = false
    @State private var showingDeleteConfirmation = false
    @State private var showingSleepTimer = false
    @State private var showingPlaybackSpeed = false

    // Volume
    @State private var currentVolume: Float = AVAudioSession.sharedInstance().outputVolume
    @State private var volumeObserver: NSKeyValueObservation?

    // MARK: - Computed

    var sortedChapters: [Chapter]? {
        audiobook.chapters?.sorted(by: { $0.index < $1.index })
    }

    /// Index of the chapter currently being played, for highlighting and
    /// scroll-to-current in the chapter list.
    var currentChapterIndex: Int? {
        guard let chapters = sortedChapters, let time = playerService?.currentPosition else {
            return nil
        }
        return chapters.last(where: { $0.startTime <= time })?.index
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundArtworkView

            VStack(spacing: 0) {
                if audiobook.playabilityState.isPlayable {
                    if isLoadingPlayer {
                        loadingSpinner
                            .padding(.bottom, 12)
                    } else if let playerService {
                        PlayerControlsView(
                            player: playerService,
                            audiobook: audiobook,
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
                if audiobook.playabilityState.isPlayable {
                    Button {
                        showingContextMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Options")
                }
            }
        }
        .sheet(isPresented: $showingChapterList) { chapterListSheet }
        .sheet(isPresented: $showingContextMenu) { contextMenuSheet }
        .sheet(isPresented: $showingSleepTimer) { sleepTimerSheet }
        .sheet(isPresented: $showingPlaybackSpeed) { playbackSpeedSheet }
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
            // Don't pause here: presenting a sheet (chapters, options, sleep
            // timer, speed) or the wrist going down triggers onDisappear, which
            // would stop playback and breaks background audio. Playback is
            // controlled explicitly and via the Now Playing controls instead.
            volumeObserver?.invalidate()
        }
    }

    // MARK: - Background

    private var backgroundArtworkView: some View {
        Group {
            if let data = audiobook.artworkData,
                let image = UIImage(data: data)
            {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: 5)
                    // Dim the bright artwork on Always-On Display to reduce
                    // burn-in and battery use while the wrist is down.
                    .opacity(isLuminanceReduced ? 0.15 : 0.5)
                    .drawingGroup()
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            if let chapters = sortedChapters, !chapters.isEmpty {
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
                .accessibilityLabel("Chapters")
            }
        }
    }

    // MARK: - Loading Spinner

    private var loadingSpinner: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        ScrollViewReader { proxy in
            List(sortedChapters ?? []) { chapter in
                let isCurrent = chapter.index == currentChapterIndex
                Button {
                    Task {
                        await playerService?.seek(to: chapter.startTime)
                        showingChapterList = false
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chapter \(chapter.index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(chapter.title)
                        }
                        Spacer()
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .listRowBackground(
                    isCurrent ? Color.accentColor.opacity(0.2) : Color.clear
                )
                .id(chapter.index)
            }
            .navigationTitle("Chapters")
            .focusable(true)
            .onAppear {
                // Jump to the chapter that's playing so the user isn't dropped
                // at the top of a 100+ chapter list.
                if let current = currentChapterIndex {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }

    // MARK: - Context Menu

    private var contextMenuSheet: some View {
        List {
            if playerService != nil {
                Section {
                    Button {
                        showingContextMenu = false
                        showingPlaybackSpeed = true
                    } label: {
                        HStack {
                            Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent")
                            Spacer()
                            if let rate = playerService?.playbackRate, rate != 1.0 {
                                Text("\(rate, specifier: "%.2f")x")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        showingContextMenu = false
                        showingSleepTimer = true
                    } label: {
                        HStack {
                            Label("Sleep Timer", systemImage: "moon")
                            Spacer()
                            if let player = playerService, player.isSleepTimerActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
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

    // MARK: - Playback Speed Sheet

    private var playbackSpeedSheet: some View {
        List {
            if let player = playerService {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                    Button {
                        player.setPlaybackRate(rate)
                        showingPlaybackSpeed = false
                    } label: {
                        HStack {
                            Text("\(rate, specifier: "%.2f")x")
                            Spacer()
                            if abs(player.playbackRate - rate) < 0.01 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playback Speed")
    }

    // MARK: - Sleep Timer Sheet

    private var sleepTimerSheet: some View {
        List {
            if let player = playerService {
                if player.isSleepTimerActive {
                    // Active timer display
                    Section {
                        VStack(alignment: .center, spacing: 8) {
                            if player.sleepAtEndOfChapter {
                                Image(systemName: "text.bookmark")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.tint)
                                Text("End of Chapter")
                                    .font(.headline)
                            } else {
                                Text(formatTime(player.sleepTimerRemaining))
                                    .font(.system(size: 48, weight: .thin, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.tint)
                                Text("remaining")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        Button(role: .destructive) {
                            player.cancelSleepTimer()
                            showingSleepTimer = false
                        } label: {
                            Text("Cancel Timer")
                        }
                    }
                } else {
                    // Timer selection
                    Section {
                        ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                            Button {
                                player.setSleepTimer(minutes: minutes)
                                showingSleepTimer = false
                            } label: {
                                HStack {
                                    Text("\(minutes) min")
                                    Spacer()
                                }
                            }
                        }
                    }

                    Section {
                        Button {
                            player.setSleepTimerEndOfChapter()
                            showingSleepTimer = false
                        } label: {
                            HStack {
                                Label("End of Chapter", systemImage: "text.bookmark")
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(playerService?.isSleepTimerActive == true ? "Timer Active" : "Sleep Timer")
    }

    // MARK: - Helpers

    private func loadPlayerIfNeeded() async {
        guard playerService == nil, audiobook.playabilityState.isPlayable else { return }
        isLoadingPlayer = true
        let service = AudioPlayerService(modelContext: modelContext)
        await service.load(audiobook: audiobook)
        playerService = service
        isLoadingPlayer = false
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

        // Take focus once so the Digital Crown drives volume on the main screen.
        // We deliberately do NOT pin focus on a repeating timer: that leaked the
        // timer for the control's lifetime and permanently hijacked the crown,
        // so sheets like the chapter list could never use it for scrolling.
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
