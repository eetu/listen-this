//
//  PreviewData.swift
//  Listen This
//

import SwiftData

enum PreviewData {
    static let chapters: [Chapter] = [
        Chapter(title: "Introduction", startTime: 0, duration: 120),
        Chapter(title: "Main Topic", startTime: 120, duration: 300),
        Chapter(title: "Conclusion", startTime: 420, duration: 90),
    ]

    static let audiobook: Audiobook = Audiobook(
        title: "Preview Book", author: "Author", chapters: PreviewData.chapters)

    static let audiobooks: [Audiobook] = [
        Audiobook(title: "The Great Adventure", author: "John Smith"),
        Audiobook(title: "Mystery at Midnight", author: "Jane Doe"),
        Audiobook(title: "Science Fiction Stories", author: "Alex Johnson"),
    ]
}

@MainActor
enum PreviewModelContext {
    static let shared: ModelContext = {
        let schema = Schema([
            Audiobook.self,
            Chapter.self,
            PlaybackSession.self,
            CacheEntry.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        return container.mainContext
    }()
}
