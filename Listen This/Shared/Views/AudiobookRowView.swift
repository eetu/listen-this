//
//  AudiobookRowView.swift
//  Listen This
//
//  Shared audiobook row component for both iOS and watchOS
//

import SwiftUI

/// Shared audiobook row view that adapts to platform
struct AudiobookRowView: View {
    let showProgress: Bool
    let isTransferring: Bool

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
        isTransferring: Bool = false
    ) {
        self.title = title
        self.author = author
        self.artworkData = artworkData
        self.duration = duration
        self.currentPosition = currentPosition
        self.playabilityState = playabilityState
        self.showProgress = showProgress
        self.isTransferring = isTransferring
    }
    
    /// Initialize directly from audiobook (captures values at init time)
    /// Used by watchOS where the detached object issue is less common
    init(audiobook: Audiobook, showProgress: Bool = true, isTransferring: Bool = false) {
        self.showProgress = showProgress
        self.isTransferring = isTransferring
        
        // Capture all values at init to resolve faults and avoid accessing detached SwiftData objects
        self.title = audiobook.title
        self.author = audiobook.author
        self.artworkData = audiobook.artworkData
        self.duration = audiobook.duration
        self.currentPosition = audiobook.playbackSession?.currentPosition ?? 0
        self.playabilityState = audiobook.playabilityState
    }

    private var showStatusIcon: Bool {
        isTransferring || playabilityState != .cached
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Artwork thumbnail with status badge overlay
            artwork
                .overlay(alignment: .bottomTrailing) {
                    if showStatusIcon {
                        statusIcon
                            #if os(iOS)
                                .font(.caption)
                                .padding(4)
                            #else
                                .font(.system(size: 10))
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
                .drawingGroup()
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

    @ViewBuilder
    private var statusIcon: some View {
        if isTransferring {
            ProgressView()
                #if os(iOS)
                    .controlSize(.small)
                #else
                    .controlSize(.mini)
                #endif
        } else {
            if playabilityState != .cached {
                Image(systemName: playabilityState.iconName)
                    .foregroundStyle(playabilityState.color)
            }
        }
    }
}
