//
//  ContentView.swift
//  listen this
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var audiobooks: [Audiobook]

    @State private var selectedAudiobook: Audiobook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Always show library list
            LibraryView(selectedAudiobook: $selectedAudiobook)
                .navigationTitle("Library")
        } detail: {
            // Detail: Show player when audiobook is selected
            if let audiobook = selectedAudiobook {
                PlayerView(audiobook: audiobook)
                    .id("player-\(audiobook.id)")  // Maintain view identity
            } else {
                LibraryEmptyView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedAudiobook) { _, newValue in
            if newValue != nil {
                // When an audiobook is selected, show detail (collapse sidebar on compact)
                columnVisibility = .detailOnly
            }
        }
        .onChange(of: horizontalSizeClass) { oldValue, newValue in
            // Reset column visibility when size class changes to allow proper adaptation
            if oldValue != newValue {
                if selectedAudiobook != nil {
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = .automatic
                }
            }
        }
    }
}

#Preview("iPhone") {
    ContentView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
        .environment(\.horizontalSizeClass, .compact)
}
#Preview("iPad") {
    ContentView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
        .environment(\.horizontalSizeClass, .regular)
}
