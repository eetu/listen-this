//
//  Listen_ThisApp.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData

@main
struct Listen_ThisWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .modelContainer(for: [Audiobook.self, Chapter.self, PlaybackSession.self, CacheEntry.self])
    }
}
