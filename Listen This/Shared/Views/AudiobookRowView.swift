//
//  AudiobookRowView.swift
//  Listen This
//
//  Shared audiobook row component for both iOS and watchOS
//

import SwiftUI

/// Shared audiobook row view that adapts to platform
struct AudiobookRowView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    let showProgress: Bool
    let isTransferring: Bool
    /// Bytes from an interrupted transfer are on disk, but the book isn't
    /// playable yet.
    let hasPartialDownload: Bool
    /// Completion fraction of an in-flight transfer, when it's known. Drives a
    /// determinate ring over the artwork instead of an indeterminate spinner,
    /// so a background download is legible at a glance from the library.
    let transferProgress: Double?

    // Pre-captured values to prevent detached object crashes
    private let title: String
    private let author: String
    private let artworkData: Data?
    private let duration: Double
    private let currentPosition: Double
    private let playabilityState: AudiobookPlayabilityState

    #if os(iOS)
        private let artworkSize: CGFloat = 60
        private let cornerRadius: CGFloat = 8
    #else
        private let artworkSize: CGFloat = 50
        private let cornerRadius: CGFloat = 6
    #endif

    /// Initialize with pre-captured values (preferred for iOS to avoid detached object crashes)
    init(
        title: String,
        author: String,
        artworkData: Data?,
        duration: Double,
        currentPosition: Double,
        playabilityState: AudiobookPlayabilityState,
        showProgress: Bool = true,
        isTransferring: Bool = false,
        transferProgress: Double? = nil,
        hasPartialDownload: Bool = false
    ) {
        self.title = title
        self.author = author
        self.artworkData = artworkData
        self.duration = duration
        self.currentPosition = currentPosition
        self.playabilityState = playabilityState
        self.showProgress = showProgress
        self.isTransferring = isTransferring
        self.transferProgress = transferProgress
        self.hasPartialDownload = hasPartialDownload
    }

    /// Initialize directly from audiobook (captures values at init time)
    /// Used by watchOS where the detached object issue is less common
    /// - Parameter hasPartialDownload: overrides the on-disk check when the
    ///   caller knows about resumable state the model can't see — an
    ///   interrupted Audiobookshelf transfer keeps its bytes inside URLSession's
    ///   resume data rather than in a partial file.
    init(
        audiobook: Audiobook,
        showProgress: Bool = true,
        isTransferring: Bool = false,
        transferProgress: Double? = nil,
        hasPartialDownload: Bool? = nil
    ) {
        self.showProgress = showProgress
        self.isTransferring = isTransferring
        self.transferProgress = transferProgress
        self.hasPartialDownload = hasPartialDownload ?? audiobook.hasPartialDownload

        // Capture all values at init to resolve faults and avoid accessing detached SwiftData objects
        self.title = audiobook.title
        self.author = audiobook.author
        self.artworkData = audiobook.artworkData
        self.duration = audiobook.duration
        self.currentPosition = audiobook.playbackSession?.currentPosition ?? 0
        self.playabilityState = audiobook.playabilityState
    }

    /// The determinate ring already conveys "transferring", so the corner badge
    /// would only duplicate it.
    private var showStatusIcon: Bool {
        guard transferProgress == nil else { return false }
        return isTransferring || hasPartialDownload || playabilityState != .cached
    }

    #if os(iOS)
        private let ringWidth: CGFloat = 4
        private let ringInset: CGFloat = 6
    #else
        private let ringWidth: CGFloat = 4
        private let ringInset: CGFloat = 4
    #endif

    /// Single spoken description so VoiceOver reads the row as one element,
    /// including transfer/playability state and progress that are otherwise
    /// only conveyed visually.
    private var accessibilityDescription: String {
        var parts = ["\(title), by \(author)"]
        if let transferProgress {
            parts.append("Downloading, \(Int(transferProgress * 100)) percent")
        } else if isTransferring {
            parts.append("Transferring")
        } else if hasPartialDownload {
            parts.append("Partly downloaded")
        } else if playabilityState != .cached {
            parts.append(playabilityState.statusText)
        }
        if showProgress, duration > 0, currentPosition > 0 {
            parts.append("\(Int((currentPosition / duration) * 100)) percent played")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Artwork thumbnail with transfer ring / status badge overlay
            artwork
                .overlay {
                    if let transferProgress {
                        transferRing(transferProgress)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showStatusIcon {
                        statusIcon
                            #if os(iOS)
                                .font(.caption)
                                .padding(4)
                            #else
                                .font(.caption2)
                                .padding(3)
                            #endif
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .offset(x: 2, y: 2)
                    }
                }

            // Book info
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)

                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                #if os(iOS)
                    // Progress indicator (iOS only)
                    if showProgress, currentPosition > 0 {
                        ProgressView(value: currentPosition, total: duration)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                    }
                #endif
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkData = artworkData,
            let uiImage = UIImage(data: artworkData)
        {
            Image(uiImage: uiImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                #if os(watchOS)
                // Rasterize via Metal for smoother scrolling, but not under
                // reduced luminance (Always-On Display / background), where GPU
                // submissions are rejected and would log Metal errors.
                .drawingGroupIfActive(isLuminanceReduced: isLuminanceReduced)
                #endif
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.gray.opacity(0.3))
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    Image(systemName: "book.fill")
                        .foregroundStyle(.secondary)
                }
        }
    }

    /// Determinate ring drawn over a dimmed thumbnail, so an in-flight download
    /// reads at a glance from the library list without opening its sheet.
    private func transferRing(_ fraction: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.black.opacity(0.5))

            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: ringWidth)
                .padding(ringInset)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    // Explicitly blue, matching TransferProgressView. The
                    // accent colour renders invisibly against the dimmed
                    // artwork on watchOS.
                    Color.blue,
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(ringInset)
                .animation(.easeInOut(duration: 0.3), value: fraction)
        }
        .frame(width: artworkSize, height: artworkSize)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isTransferring {
            ProgressView()
                #if os(iOS)
                    .controlSize(.small)
                #else
                    .controlSize(.mini)
                #endif
        } else if hasPartialDownload {
            // Distinct from both "downloaded" and "not downloaded": bytes are
            // on disk, but the book isn't playable until the rest arrives.
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.orange)
        } else if playabilityState != .cached {
            Image(systemName: playabilityState.iconName)
                .foregroundStyle(playabilityState.color)
        }
    }
}

private extension View {
    /// Apply drawingGroup() only when the display is at full luminance. Under
    /// reduced luminance (Always-On Display / background) the system rejects GPU
    /// submissions, so the Metal-backed rasterization must be skipped.
    @ViewBuilder
    func drawingGroupIfActive(isLuminanceReduced: Bool) -> some View {
        if isLuminanceReduced {
            self
        } else {
            drawingGroup()
        }
    }
}
