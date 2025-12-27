//
//  TestHelpers.swift
//  Listen This AppTests
//
//  Shared test utilities and fixtures
//

import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Test Container Helpers

/// Create in-memory model container for testing
@MainActor
func createTestContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self,
        configurations: config
    )
}

/// Create in-memory model container with PlaybackSession support
@MainActor
func createTestContainerWithPlayback() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: Audiobook.self, Chapter.self, CacheEntry.self, PlaybackSession.self,
        configurations: config
    )
}

// MARK: - Test Data Helpers

/// Create test audiobook with configurable properties
@MainActor
func createTestAudiobook(title: String = "Test Book", fileSize: Int64 = 100_000_000) -> Audiobook {
    let audiobook = Audiobook(
        title: title,
        author: "Test Author",
        narrator: "Test Narrator",
        duration: 3600,
        fileSize: fileSize
    )
    audiobook.localFilename = "\(audiobook.id).m4b"
    return audiobook
}

/// Create temporary test file with specified size
func createTestFile(size: Int64 = 1_000_000) throws -> URL {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".m4b")
    let data = Data(repeating: 0, count: Int(size))
    try data.write(to: tempURL)
    return tempURL
}
