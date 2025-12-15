//
//  WatchAudiobookRow.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI

struct WatchAudiobookRow: View {
    let audiobook: Audiobook
    
    var body: some View {
        HStack(spacing: 10) {
            // Artwork thumbnail
            if let artworkData = audiobook.artworkData,
               let uiImage = UIImage(data: artworkData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(audiobook.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                Text(audiobook.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                // Show cache status
                if audiobook.isCached {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Label("Not cached", systemImage: "icloud.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let audiobook = Audiobook(
        title: "Sample Audiobook",
        author: "John Doe",
        duration: 36000,
        isCached: true
    )
    
    return WatchAudiobookRow(audiobook: audiobook)
}
