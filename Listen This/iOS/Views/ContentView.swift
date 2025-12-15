//
//  ContentView.swift
//  listen this
//
//  Created by Eetu Sutinen on 13.12.2025.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
}
