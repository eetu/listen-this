//
//  ContentView.swift
//  listen this
//
//  Created by Eetu Sutinen on 13.12.2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query private var audiobooks: [Audiobook]

    @State private var selectedAudiobook: Audiobook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad: Split view with sidebar
            iPadLayout
        } else {
            // iPhone: Standard stack navigation (existing behavior)
            LibraryView()
        }
    }

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView(selectedAudiobook: $selectedAudiobook)
                .navigationTitle("Library")
        } detail: {
            if let audiobook = selectedAudiobook {
                PlayerView(audiobook: audiobook)
            } else {
                LibraryDetailView()
            }
        }
        .onChange(of: selectedAudiobook) { _, newValue in
            if newValue != nil {
                // Collapse sidebar when audiobook is selected
                withAnimation {
                    columnVisibility = .detailOnly
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

