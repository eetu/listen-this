//
//  AudiobookRowView.swift
//  Listen This
//
//  Shared audiobook row component for both iOS and watchOS
//

import SwiftUI

/// Shared audiobook row view that adapts to platform
struct AudiobookRowView: View {
    let audiobook: Audiobook
    let showProgress: Bool
    let isTransferring: Bool

    #if os(iOS)
        private let artworkSize: CGFloat = 60
        private let cornerRadius: CGFloat = 8
    #else
        private let artworkSize: CGFloat = 50
        private let cornerRadius: CGFloat = 6
    #endif

    init(audiobook: Audiobook, showProgress: Bool = true, isTransferring: Bool = false) {
        self.audiobook = audiobook
        self.showProgress = showProgress
        self.isTransferring = isTransferring
    }

    private var showStatusIcon: Bool {
        isTransferring || audiobook.playabilityState != .cached
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
                Text(audiobook.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)

                Text(audiobook.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                #if os(iOS)
                    // Progress indicator (iOS only)
                    if showProgress,
                        let session = audiobook.playbackSession,
                        session.currentPosition > 0
                    {
                        ProgressView(value: session.currentPosition, total: audiobook.duration)
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
        if let artworkData = audiobook.artworkData,
            let uiImage = UIImage(data: artworkData)
        {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
            let state = audiobook.playabilityState
            if state != .cached {
                Image(systemName: state.iconName)
                    .foregroundStyle(state.color)
            }
        }
    }
}
