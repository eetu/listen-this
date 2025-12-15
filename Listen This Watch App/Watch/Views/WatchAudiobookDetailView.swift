//
//  WatchAudiobookDetailView.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI

struct WatchAudiobookDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let audiobook: Audiobook
    @State private var showingPlayer = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Artwork
                if let artworkData = audiobook.artworkData,
                   let uiImage = UIImage(data: artworkData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "book.closed")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                
                // Title and Author
                VStack(spacing: 4) {
                    Text(audiobook.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    Text(audiobook.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Duration and chapters
                HStack(spacing: 16) {
                    Label(formatDuration(audiobook.duration), systemImage: "clock")
                        .font(.caption2)
                    
                    if audiobook.chapterCount > 0 {
                        Label("\(audiobook.chapterCount) chapters", systemImage: "list.bullet")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                
                // Progress
                if let session = audiobook.playbackSession {
                    VStack(spacing: 4) {
                        ProgressView(value: session.progressPercentage, total: 100)
                        
                        Text("\(Int(session.progressPercentage))% complete")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                
                // Action buttons
                if audiobook.isCached {
                    Button {
                        showingPlayer = true
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        // Download action
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle(audiobook.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingPlayer) {
            WatchPlayerView(audiobook: audiobook)
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

#Preview {
    let audiobook = Audiobook(
        title: "Sample Audiobook",
        author: "John Doe",
        duration: 36000,
        isCached: true,
        chapterCount: 25
    )
    
    WatchAudiobookDetailView(audiobook: audiobook)
}
