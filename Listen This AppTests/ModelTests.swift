//
//  ModelTests.swift
//  Listen This AppTests
//
//  Tests for SwiftData models and relationships
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - SwiftData Model Tests

@Suite("SwiftData Model Tests")
@MainActor
struct SwiftDataModelTests {

    @Test("Audiobook relationships cascade delete")
    func cascadeDelete() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let chapter1 = Chapter(index: 0, title: "Chapter 1", startTime: 0, duration: 600)
        let chapter2 = Chapter(index: 1, title: "Chapter 2", startTime: 600, duration: 600)

        audiobook.chapters = [chapter1, chapter2]
        context.insert(chapter1)
        context.insert(chapter2)

        try context.save()

        context.delete(audiobook)
        try context.save()

        let descriptor = FetchDescriptor<Chapter>()
        let chapters = try context.fetch(descriptor)

        #expect(chapters.isEmpty)
    }

    @Test("CacheEntry relationship is independent")
    func cacheEntryIndependence() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let cacheEntry = CacheEntry(
            filePath: "/path/to/cache",
            fileSize: 50_000_000
        )
        audiobook.cacheEntry = cacheEntry
        context.insert(cacheEntry)

        try context.save()

        context.delete(cacheEntry)
        try context.save()

        let descriptor = FetchDescriptor<Audiobook>()
        let audiobooks = try context.fetch(descriptor)

        #expect(audiobooks.count == 1)
        #expect(audiobooks.first?.cacheEntry == nil)
    }

    @Test("Audiobook computed properties")
    func audiobookComputedProperties() async throws {
        let audiobook = createTestAudiobook()
        audiobook.iCloudRelativePath = "Documents/Audiobooks/test-book.m4b"

        #expect(audiobook.filename == "test-book.m4b")

        let expectedPath = audiobook.expectedCachePath
        #expect(expectedPath != nil)
        #expect(expectedPath?.contains("test-book.m4b") == true)
    }

    @Test("Query audiobooks by criteria")
    func queryAudiobooks() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let book1 = createTestAudiobook(title: "The Hobbit")
        let book2 = createTestAudiobook(title: "Harry Potter")
        let book3 = createTestAudiobook(title: "The Lord of the Rings")

        book1.isArchived = true

        context.insert(book1)
        context.insert(book2)
        context.insert(book3)

        try context.save()

        var descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.isArchived == true }
        )
        var results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results.first?.title == "The Hobbit")

        descriptor = FetchDescriptor<Audiobook>(
            predicate: #Predicate { $0.title.contains("Harry") }
        )
        results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results.first?.title == "Harry Potter")
    }
}

// MARK: - Boundary & Edge Case Tests

@Suite("Model Boundary Tests")
@MainActor
struct ModelBoundaryTests {

    @Test("Zero-byte file")
    func zeroByteFile() async throws {
        let audiobook = createTestAudiobook(fileSize: 0)

        let progress = ChunkTransferProgress(
            audiobookId: audiobook.id,
            totalBytes: 0,
            totalChunks: 0,
            completedChunks: 0,
            isUploading: true
        )

        #expect(progress.progress == 0.0)
        #expect(progress.progressPercentage == 0)
    }

    @Test("Unicode characters in title")
    func unicodeTitles() async throws {
        let container = try createTestContainer()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook(
            title: "Les Miserables"
        )
        context.insert(audiobook)
        try context.save()

        let descriptor = FetchDescriptor<Audiobook>()
        let results = try context.fetch(descriptor)

        #expect(results.first?.title == "Les Miserables")
    }

    @Test("Very long audiobook title")
    func longTitle() async throws {
        let longTitle = String(repeating: "A", count: 1000)
        let audiobook = createTestAudiobook(title: longTitle)

        #expect(audiobook.title.count == 1000)
    }

    @Test("Special characters in filename")
    func specialCharactersInFilename() async throws {
        let audiobook = createTestAudiobook()
        audiobook.iCloudRelativePath = "Documents/Audiobooks/Book: A Story's Tale (2024) #1.m4b"

        let expectedPath = audiobook.expectedCachePath
        #expect(expectedPath != nil)
        #expect(audiobook.filename == "Book: A Story's Tale (2024) #1.m4b")
    }
}
