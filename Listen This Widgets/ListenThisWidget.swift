//
//  ListenThisWidget.swift
//  Listen This Widgets
//
//  WidgetKit complications for watch faces. The timeline data and the shared
//  accessory views live in Shared/Widgets/NowPlayingWidgetData.swift.
//

import SwiftUI
import WidgetKit

// MARK: - Widget Views

// Graphic Corner - Progress percentage with gauge, or icon if no audiobook
struct GraphicCornerView: View {
    let entry: AudiobookEntry

    var body: some View {
        if entry.hasBook {
            // Stacked text: percentage + chapter info
            VStack(spacing: 0) {
                if entry.totalChapters > 0 {
                    Text("Ch \(entry.chapterIndex + 1)/\(entry.totalChapters)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Int(entry.progress * 100))%")
                        .foregroundStyle(.secondary)
                }
            }
            .widgetCurvesContent()
            .widgetLabel {
                Text(entry.title)
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
                GraphicInlineView(entry: entry)
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
