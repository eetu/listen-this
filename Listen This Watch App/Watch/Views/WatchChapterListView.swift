//
//  WatchChapterListView.swift
//  listen this Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI

struct WatchChapterListView: View {
    let chapters: [Chapter]
    let currentChapterIndex: Int
    let onSelectChapter: (Chapter) -> Void
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        onSelectChapter(chapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                
                                Text("\(formatDuration(chapter.duration))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if index == currentChapterIndex {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

#Preview {
    let chapters = [
        Chapter(index: 0, title: "Introduction", startTime: 0, duration: 600),
        Chapter(index: 1, title: "Chapter 1: The Beginning", startTime: 600, duration: 1200),
        Chapter(index: 2, title: "Chapter 2: The Journey", startTime: 1800, duration: 1500)
    ]
    
    return WatchChapterListView(chapters: chapters, currentChapterIndex: 1) { _ in }
}
