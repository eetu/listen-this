//
//  Listen_This_iPhone_Widgets.swift
//  Listen This iPhone Widgets
//
//  Home Screen and Lock Screen widgets showing the current audiobook. The
//  timeline data and accessory views are shared with the Watch complications
//  (Shared/Widgets/NowPlayingWidgetData.swift).
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Widget Configuration

struct Listen_This_iPhone_Widgets: Widget {
    let kind: String = "ListenThisNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AudiobookTimelineProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Current Audiobook")
        .description("Shows the book you're listening to and how far along you are.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Entry View

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AudiobookEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallNowPlayingView(entry: entry)
        case .systemMedium:
            MediumNowPlayingView(entry: entry)
        case .accessoryCircular:
            GraphicCircularView(entry: entry)
        case .accessoryRectangular:
            GraphicRectangularView(entry: entry)
        case .accessoryInline:
            GraphicInlineView(entry: entry)
        default:
            EmptyView()
        }
    }
}

// MARK: - Home Screen Views

/// The cover fills the widget; the title, time left and play/pause button sit
/// on an opaque rounded panel so they stay readable on any cover.
private struct SmallNowPlayingView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    let entry: AudiobookEntry

    /// In tinted or clear Home Screen modes the system drops the background,
    /// so text falls back to the standard style.
    private var overCover: Bool {
        entry.artwork != nil && renderingMode == .fullColor
    }

    /// Brighter than .secondary on the dark panel, where it read too dim.
    private var captionStyle: AnyShapeStyle {
        overCover && colorScheme == .dark
            ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        Group {
            if entry.hasBook {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(alignment: .center, spacing: 8) {
                            Text(timeLeftText(entry.remaining) ?? "")
                                .font(.caption2)
                                .foregroundStyle(captionStyle)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            PlayPauseButton(isPlaying: entry.isPlaying, size: 32)
                        }
                    }
                    .padding(overCover ? 10 : 0)
                    .background {
                        if overCover {
                            // The medium widget's background (.fill.tertiary
                            // over the system background), made opaque so
                            // cover text can't show through the captions.
                            // Follows light/dark mode. ContainerRelativeShape
                            // keeps the corners concentric with the widget's.
                            ContainerRelativeShape()
                                .fill(.background)
                                .overlay(ContainerRelativeShape().fill(.fill.tertiary))
                        }
                    }
                    // Tuck the panel toward the widget's rounded edge.
                    .padding(overCover ? -6 : 0)
                }
                // Primary text follows the mode: white on the dark panel,
                // black on the light one.
                .foregroundStyle(.primary)
            } else {
                EmptyNowPlayingView()
            }
        }
        .containerBackground(for: .widget) {
            if entry.hasBook, let artwork = entry.artwork {
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.fill.tertiary)
            }
        }
    }
}

private struct MediumNowPlayingView: View {
    let entry: AudiobookEntry

    var body: some View {
        Group {
            if entry.hasBook {
                HStack(spacing: 14) {
                    CoverArt(image: entry.artwork)
                        .aspectRatio(1, contentMode: .fit)

                    VStack(alignment: .leading, spacing: 3) {
                        // Full width for the title; the button lives in the
                        // bottom row so long titles get room before truncating.
                        Text(entry.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !entry.author.isEmpty {
                            Text(entry.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                if let chapterTitle = entry.chapterTitle, !chapterTitle.isEmpty {
                                    Text(chapterTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                // No progress bar: it looks draggable but a tap
                                // only opens the app.
                                if let timeLeft = timeLeftText(entry.remaining) {
                                    Text(timeLeft)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            PlayPauseButton(isPlaying: entry.isPlaying, size: 36)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyNowPlayingView()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Components

/// Plays or pauses without opening the app; runs `TogglePlaybackIntent` in the
/// app's process.
private struct PlayPauseButton: View {
    let isPlaying: Bool
    let size: CGFloat

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

/// The cover, or a book symbol when there's no artwork.
private struct CoverArt: View {
    let image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "book.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Concentric with the widget's own corners.
        .clipShape(ContainerRelativeShape())
    }
}

/// "2h 14m left", or nil when the book is finished.
private func timeLeftText(_ remaining: TimeInterval) -> String? {
    guard remaining > 0 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: remaining).map { "\($0) left" }
}

private struct EmptyNowPlayingView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No audiobook yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
    extension AudiobookEntry {
        /// The placeholder with a generated stand-in cover, to preview the
        /// full-bleed layout.
        static var previewWithCover: AudiobookEntry {
            previewCover(colors: [.systemRed, .systemIndigo])
        }

        /// A light, busy cover: the hard case for text contrast.
        static var previewWithLightCover: AudiobookEntry {
            previewCover(colors: [.white, .systemYellow, .white, .systemCyan])
        }

        /// A long title, to check wrapping and truncation.
        static var previewLongTitle: AudiobookEntry {
            let base = previewWithCover
            return AudiobookEntry(
                date: base.date,
                title: "The Hitchhiker's Guide to the Galaxy: The Complete Radio Series",
                author: "Douglas Adams", progress: 0.3, chapterIndex: 3, totalChapters: 12,
                chapterTitle: "Fit the Fourth", remaining: 5 * 3600 + 40 * 60,
                artwork: base.artwork, isPlaying: true)
        }

        private static func previewCover(colors uiColors: [UIColor]) -> AudiobookEntry {
            // Scale 1: WidgetKit rejects images over ~1000 px, as the real
            // thumbnail (600 px) respects.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: 600, height: 600), format: format)
            let cover = renderer.image { context in
                let colors = uiColors.map(\.cgColor) as CFArray
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)!
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
            }
            let base = AudiobookEntry.placeholder
            return AudiobookEntry(
                date: base.date, title: base.title, author: base.author,
                progress: base.progress, chapterIndex: base.chapterIndex,
                totalChapters: base.totalChapters, chapterTitle: base.chapterTitle,
                remaining: base.remaining, artwork: cover.cgImage, isPlaying: false)
        }
    }
#endif

#Preview("Small", as: .systemSmall) {
    Listen_This_iPhone_Widgets()
} timeline: {
    AudiobookEntry.previewWithLightCover
    AudiobookEntry.previewWithCover
    AudiobookEntry.placeholder
    AudiobookEntry.empty
}

#Preview("Medium", as: .systemMedium) {
    Listen_This_iPhone_Widgets()
} timeline: {
    AudiobookEntry.previewLongTitle
    AudiobookEntry.previewWithCover
    AudiobookEntry.placeholder
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    Listen_This_iPhone_Widgets()
} timeline: {
    AudiobookEntry.placeholder
}
