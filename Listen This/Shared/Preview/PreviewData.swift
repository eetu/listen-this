//
//  PreviewData.swift
//  Listen This
//
//  Created by Eetu Sutinen on 23.12.2025.
//

enum PreviewData {
    static let chapters: [Chapter] = [
        Chapter(title: "Introduction", startTime: 0, duration: 120),
        Chapter(title: "Main Topic", startTime: 120, duration: 300),
        Chapter(title: "Conclusion", startTime: 420, duration: 90)
    ]
    
    static let audiobook: Audiobook = Audiobook(title: "Preview Book", author: "Author", chapters: PreviewData.chapters)
}
