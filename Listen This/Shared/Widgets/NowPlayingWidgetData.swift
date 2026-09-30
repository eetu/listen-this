//
//  NowPlayingWidgetData.swift
//  Listen This
//
//  Timeline data and accessory views shared by the Watch complications and the
//  iPhone Home Screen / Lock Screen widgets
//

import ImageIO
import SwiftData
import SwiftUI
import WidgetKit

#if os(iOS)
    import AppIntents
#endif

// MARK: - Widget Entry

struct AudiobookEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String
    let progress: Double
    let chapterIndex: Int
    let totalChapters: Int
    let chapterTitle: String?
    /// Listening time left in the book, in seconds.
    let remaining: TimeInterval
    /// Downscaled cover. Only loaded where a widget shows it (not on Watch).
    let artwork: CGImage?
    /// Only known on iPhone, where the app shares its playback state.
    let isPlaying: Bool

    var hasBook: Bool { !title.isEmpty }

    static var placeholder: AudiobookEntry {
        AudiobookEntry(
            date: Date(),
            title: "All Systems Red",
            author: "Martha Wells",
            progress: 0.65,
            chapterIndex: 7,
            totalChapters: 12,
            chapterTitle: "Chapter Eight",
            remaining: 2 * 3600 + 14 * 60,
            artwork: nil,
            isPlaying: true
        )
    }

    static var empty: AudiobookEntry {
        AudiobookEntry(
            date: Date(),
            title: "",
            author: "",
            progress: 0,
            chapterIndex: 0,
            totalChapters: 0,
            chapterTitle: nil,
            remaining: 0,
            artwork: nil,
            isPlaying: false
        )
    }
}

// MARK: - Playback State

/// Whether the app is playing, shared with the widgets through the App Group.
/// The widget can't observe the player, so the app writes this on every
/// play/pause change.
nonisolated enum WidgetPlaybackState {
    static let appGroup = "group.com.anarkisti.Listen-This"

    private static let isPlayingKey = "widget.isPlaying"
    private static let audiobookIDKey = "widget.audiobookID"
    private static let updatedAtKey = "widget.updatedAt"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(isPlaying: Bool, audiobookID: UUID?) {
        guard let defaults else { return }
        defaults.set(isPlaying, forKey: isPlayingKey)
        defaults.set(audiobookID?.uuidString, forKey: audiobookIDKey)
        defaults.set(Date(), forKey: updatedAtKey)
    }

    /// Whether this book is playing. A playing app saves its position every
    /// 30 seconds, so if neither that nor this state changed for two minutes,
    /// the app was stopped without pausing (e.g. force-quit) and the stored
    /// "playing" is stale.
    static func isPlaying(audiobookID: UUID, lastPlayed: Date) -> Bool {
        guard let defaults, defaults.bool(forKey: isPlayingKey),
            defaults.string(forKey: audiobookIDKey) == audiobookID.uuidString
        else { return false }
        let updatedAt = defaults.object(forKey: updatedAtKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(max(updatedAt, lastPlayed)) < 120
    }
}

#if os(iOS)
    // MARK: - Play/Pause Intent

    /// Where the app plugs in its player. The intent runs in the app's process
    /// (an `AudioPlaybackIntent`), and the app sets this at launch; in the
    /// widget process it stays nil.
    @MainActor
    enum PlaybackControl {
        static var toggle: (() async -> Void)?

        static func run() async {
            await toggle?()
        }
    }

    /// Plays or pauses the current audiobook from a widget button. Resumes the
    /// most recently played book when nothing is loaded.
    nonisolated struct TogglePlaybackIntent: AudioPlaybackIntent {
        static let title: LocalizedStringResource = "Play or Pause Audiobook"
        static let description = IntentDescription(
            "Resumes or pauses the audiobook you're listening to.")

        init() {}

        func perform() async throws -> some IntentResult {
            await PlaybackControl.run()
            return .result()
        }
    }
#endif

// MARK: - Timeline Provider

struct AudiobookTimelineProvider: TimelineProvider {

    private static let appGroup = WidgetPlaybackState.appGroup

    func placeholder(in context: Context) -> AudiobookEntry {
        .placeholder
    }

    /// How far ahead a playing book's progress is projected, one entry a minute.
    /// The app reloads about every five minutes while playing (and on
    /// pause/seek), which replaces the projection; this covers the gaps when
    /// iOS delays those reloads.
    private static let projectionMinutes = 15

    func getSnapshot(in context: Context, completion: @escaping (AudiobookEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(entries().first ?? .empty)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AudiobookEntry>) -> Void)
    {
        let nextUpdate =
            Calendar.current.date(byAdding: .minute, value: Self.projectionMinutes, to: Date())
            ?? Date()
        completion(Timeline(entries: entries(), policy: .after(nextUpdate)))
    }

    /// Opens the app's store read-only in spirit: no CloudKit here, the app
    /// owns syncing. The location must match where each app keeps its store.
    private func makeContainer() -> ModelContainer? {
        let schema = Schema([
            Audiobook.self,
            Chapter.self,
            PlaybackSession.self,
            CacheEntry.self,
            UserSettings.self,
            AudiobookshelfSettings.self,
        ])

        #if os(watchOS)
            // The Watch app stores at an explicit URL in the App Group root.
            guard
                let groupURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: Self.appGroup)
            else { return nil }
            let configuration = ModelConfiguration(
                schema: schema,
                url: groupURL.appendingPathComponent("default.store"),
                cloudKitDatabase: .none
            )
        #else
            // The iPhone app uses the default configuration, which SwiftData
            // places in the App Group container; name it the same way.
            let configuration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(Self.appGroup),
                cloudKitDatabase: .none
            )
        #endif

        return try? ModelContainer(for: schema, configurations: [configuration])
    }

    /// The current entry, followed while playing by one projected entry per
    /// minute so progress and time left advance without reloads.
    private func entries() -> [AudiobookEntry] {
        guard let container = makeContainer() else { return [.empty] }
        let context = ModelContext(container)

        // The most recently played audiobook
        var descriptor = FetchDescriptor<PlaybackSession>(
            sortBy: [SortDescriptor(\.lastPlayed, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let session = try? context.fetch(descriptor).first,
            let audiobook = session.audiobook
        else {
            return [.empty]
        }

        let duration = audiobook.duration
        let chapters = (audiobook.chapters ?? []).sorted { $0.index < $1.index }
        let isPlaying = WidgetPlaybackState.isPlaying(
            audiobookID: audiobook.id, lastPlayed: session.lastPlayed)

        #if os(watchOS)
            let artwork: CGImage? = nil
        #else
            // Large enough to fill a small widget edge to edge.
            let artwork = audiobook.artworkData.flatMap { Self.thumbnail(from: $0, maxPixelSize: 600) }
        #endif

        func entry(at date: Date, position rawPosition: Double) -> AudiobookEntry {
            let position = min(max(rawPosition, 0), duration)
            let chapterIndex =
                chapters.firstIndex { chapter in
                    let end = chapter.startTime + chapter.duration
                    return chapter.startTime <= position
                        && (end > position || chapter.duration == 0)
                } ?? 0
            return AudiobookEntry(
                date: date,
                title: audiobook.title,
                author: audiobook.author,
                progress: duration > 0 ? position / duration : 0,
                chapterIndex: chapterIndex,
                totalChapters: chapters.count,
                chapterTitle: chapters.indices.contains(chapterIndex)
                    ? chapters[chapterIndex].title : nil,
                remaining: duration - position,
                artwork: artwork,
                isPlaying: isPlaying
            )
        }

        let now = Date()
        guard isPlaying else {
            return [entry(at: now, position: session.currentPosition)]
        }

        // The saved position is up to 30 s old while playing; count the
        // listening since the save. Progress runs at the playback speed.
        let rate = session.playbackRate > 0 ? session.playbackRate : 1
        let start = session.currentPosition + max(now.timeIntervalSince(session.lastPlayed), 0) * rate
        return (0...Self.projectionMinutes).map { minute in
            let elapsed = TimeInterval(minute * 60)
            return entry(at: now.addingTimeInterval(elapsed), position: start + elapsed * rate)
        }
    }

    /// Decodes a small thumbnail straight from the image data. Widget
    /// extensions have a tight memory limit, so the full-size cover is never
    /// decoded.
    private static func thumbnail(from data: Data, maxPixelSize: Int = 400) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Accessory Views (Watch faces and iPhone Lock Screen)

/// Progress ring with a book icon.
struct GraphicCircularView: View {
    let entry: AudiobookEntry

    var body: some View {
        ProgressView(value: entry.progress) {
            Image(systemName: "book.fill")
                .font(.title2)
        }
        .progressViewStyle(.circular)
        .tint(.green)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

/// Title, author and a progress bar.
struct GraphicRectangularView: View {
    let entry: AudiobookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.hasBook ? entry.title : "No Audiobook")
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
                .lineLimit(1)

            if !entry.author.isEmpty {
                Text(entry.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Gauge(value: entry.progress) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(.green)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

/// One line for the inline accessory family.
struct GraphicInlineView: View {
    let entry: AudiobookEntry

    var body: some View {
        if entry.hasBook {
            Text("\(entry.title) • \(Int(entry.progress * 100))%")
        } else {
            Text("No Audiobook")
        }
    }
}
