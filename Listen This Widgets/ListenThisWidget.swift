//
//  ListenThisWidget.swift
//  Listen This Widgets
//
//  WidgetKit complications for watch faces
//

import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Widget Entry

struct AudiobookEntry: TimelineEntry {
    let date: Date
    let title: String
    let author: String
    let progress: Double
    let chapterIndex: Int
    let totalChapters: Int
    let isPlaying: Bool

    static var placeholder: AudiobookEntry {
        AudiobookEntry(
            date: Date(),
            title: "All Systems Red",
            author: "Martha Wells",
            progress: 0.65,
            chapterIndex: 7,
            totalChapters: 12,
            isPlaying: true
        )
    }

    static var empty: AudiobookEntry {
        AudiobookEntry(
            date: Date(),
            title: "No Audiobook",
            author: "",
            progress: 0,
            chapterIndex: 0,
            totalChapters: 0,
            isPlaying: false
        )
    }
}

// MARK: - Timeline Provider

struct AudiobookTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> AudiobookEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (AudiobookEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(getCurrentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AudiobookEntry>) -> Void)
    {
        let entry = getCurrentEntry()

        // Update timeline every 5 minutes or when widget is tapped
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        completion(timeline)
    }

    private func getCurrentEntry() -> AudiobookEntry {
        // Access the shared database from the main app via App Group
        // The widget reads from the same local store but doesn't enable CloudKit sync
        // (only the main app should manage CloudKit syncing to avoid conflicts)

        // Try to use App Group container, fallback to default if not available
        let storeURL: URL
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.anarkisti.Listen-This"
        ) {
            storeURL = appGroupURL.appendingPathComponent("default.store")
        } else {
            // Fallback to default location - widget won't see main app data but won't crash
            storeURL = URL.applicationSupportDirectory.appending(path: "default.store")
        }

        let schema = Schema([
            Audiobook.self,
            Chapter.self,
            PlaybackSession.self,
            CacheEntry.self,
            UserSettings.self,
            AudiobookshelfSettings.self,
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL
                // Note: Do NOT enable cloudKitDatabase here - only the main app should sync
        )

        guard
            let container = try? ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        else {
            return .empty
        }

        let context = ModelContext(container)

        // Find the most recently played audiobook
        let descriptor = FetchDescriptor<PlaybackSession>(
            sortBy: [SortDescriptor(\.lastPlayed, order: .reverse)]
        )

        guard let session = try? context.fetch(descriptor).first,
            let audiobook = session.audiobook
        else {
            return .empty
        }

        // Calculate progress from session
        let currentPosition = session.currentPosition
        let progress = audiobook.duration > 0 ? currentPosition / audiobook.duration : 0

        // Get chapter info
        let allChapters = audiobook.chapters ?? []
        let chapters = allChapters.sorted(by: { $0.index < $1.index })
        let currentChapterIndex =
            chapters.firstIndex { chapter in
                let endTime = chapter.startTime + chapter.duration
                return chapter.startTime <= currentPosition
                    && (endTime > currentPosition || chapter.duration == 0)
            } ?? 0

        return AudiobookEntry(
            date: Date(),
            title: audiobook.title,
            author: audiobook.author,
            progress: progress,
            chapterIndex: currentChapterIndex,
            totalChapters: chapters.count,
            isPlaying: false  // Widget doesn't have real-time playing state
        )
    }
}

// MARK: - Widget Views

// Graphic Circular - Progress ring with book icon
struct GraphicCircularView: View {
    let entry: AudiobookEntry

    var body: some View {
        ZStack {
            // Progress ring
            ProgressView(value: entry.progress) {
                // Book icon in center
                Image(systemName: "book.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .progressViewStyle(.circular)
            .tint(.green)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

// Graphic Corner - Progress percentage with gauge, or icon if no audiobook
struct GraphicCornerView: View {
    let entry: AudiobookEntry

    var body: some View {
        if entry.title != "No Audiobook" {
            // Show progress percentage
            Text("\(Int(entry.progress * 100))%")
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: entry.progress) {
                        EmptyView()
                    }
                    .gaugeStyle(.accessoryLinear)
                    .tint(.green)
                }
                .containerBackground(for: .widget) {
                    Color.clear
                }
        } else {
            // Fallback: just show book icon
            Image(systemName: "book.fill")
                .font(.title3)
                .widgetCurvesContent()
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
    }
}

// Graphic Rectangular - Full details with progress bar
struct GraphicRectangularView: View {
    let entry: AudiobookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Book title
            Text(entry.title)
                .font(.system(.body, design: .rounded))
                .fontWeight(.semibold)
                .lineLimit(1)

            // Author and chapter
            if !entry.author.isEmpty || entry.totalChapters > 0 {
                HStack(spacing: 4) {
                    if !entry.author.isEmpty {
                        Text(entry.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            // Progress bar
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

// MARK: - Widget Configuration

struct ListenThisWidget: Widget {
    let kind: String = "ListenThisWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AudiobookTimelineProvider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Listen This")
        .description("Shows your current audiobook progress")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Widget Entry View

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: AudiobookEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                GraphicCircularView(entry: entry)
            case .accessoryCorner:
                GraphicCornerView(entry: entry)
            case .accessoryRectangular:
                GraphicRectangularView(entry: entry)
            case .accessoryInline:
                Text("\(entry.title) • \(Int(entry.progress * 100))%")
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    ListenThisWidget()
} timeline: {
    AudiobookEntry.placeholder
}

#Preview("Corner", as: .accessoryCorner) {
    ListenThisWidget()
} timeline: {
    AudiobookEntry.placeholder
}

#Preview("Rectangular", as: .accessoryRectangular) {
    ListenThisWidget()
} timeline: {
    AudiobookEntry.placeholder
}

#Preview("Inline", as: .accessoryInline) {
    ListenThisWidget()
} timeline: {
    AudiobookEntry.placeholder
}
