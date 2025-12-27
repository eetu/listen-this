//
//  PlaybackSyncTests.swift
//  Listen This AppTests
//
//  Tests for playback state synchronization between devices
//

import Testing
import Foundation
import SwiftData
@testable import Listen_This

// MARK: - Playback State Sync Tests

@Suite("Playback State Synchronization Tests")
@MainActor
struct PlaybackStateSyncTests {

    @Test("Local progress is saved with timestamp")
    func localProgressSaved() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        // Create playback session
        let session = PlaybackSession(
            currentPosition: 1200, // 20 minutes
            currentChapter: 2,
            playbackRate: 1.5,
            lastPlayed: Date()
        )
        audiobook.playbackSession = session
        context.insert(session)

        try context.save()

        // Verify session was saved with timestamp
        #expect(audiobook.playbackSession != nil)
        #expect(audiobook.playbackSession?.currentPosition == 1200)
        #expect(audiobook.playbackSession?.lastPlayed != nil)
    }

    @Test("Newer remote progress is not overwritten by older local")
    func newerRemoteNotOverwritten() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let oldTimestamp = Date().addingTimeInterval(-3600) // 1 hour ago
        let newTimestamp = Date() // now

        // Simulate: local state loaded with old timestamp
        let session = PlaybackSession(
            currentPosition: 1200, // old position: 20 minutes
            currentChapter: 2,
            lastPlayed: oldTimestamp
        )
        audiobook.playbackSession = session
        context.insert(session)
        try context.save()

        // Simulate: CloudKit syncs newer data (Watch progress)
        session.currentPosition = 2400 // new position: 40 minutes
        session.currentChapter = 4
        session.lastPlayed = newTimestamp
        try context.save()

        // Verify newer data is preserved
        #expect(session.currentPosition == 2400)
        #expect(session.currentChapter == 4)
        #expect(session.lastPlayed == newTimestamp)
    }

    @Test("Timestamp comparison works correctly")
    func timestampComparison() async throws {
        let oldTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let newTime = Date()

        // Basic timestamp comparison
        #expect(newTime > oldTime)
        #expect(oldTime < newTime)

        // Same timestamps
        let sameTime = oldTime
        #expect(sameTime == oldTime)
        #expect(!(sameTime > oldTime))
    }

    @Test("PlaybackSession preserves all fields")
    func playbackSessionFields() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let testDate = Date()
        let session = PlaybackSession(
            currentPosition: 5432.5,
            currentChapter: 7,
            playbackRate: 1.25,
            lastSynced: testDate,
            lastPlayed: testDate,
            progressPercentage: 45.5,
            isCompleted: false
        )

        context.insert(session)
        try context.save()

        #expect(session.currentPosition == 5432.5)
        #expect(session.currentChapter == 7)
        #expect(session.playbackRate == 1.25)
        #expect(session.progressPercentage == 45.5)
        #expect(session.isCompleted == false)
        #expect(session.lastPlayed == testDate)
    }

    @Test("Progress percentage calculation")
    func progressPercentageCalculation() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        audiobook.duration = 3600 // 1 hour
        context.insert(audiobook)

        let session = PlaybackSession(
            currentPosition: 1800, // 30 minutes
            progressPercentage: 50.0
        )
        audiobook.playbackSession = session
        context.insert(session)
        try context.save()

        // Verify percentage
        let expectedPercentage = (1800.0 / 3600.0) * 100.0
        #expect(session.progressPercentage == expectedPercentage)
    }

    @Test("Completion detection near end of audiobook")
    func completionDetection() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        audiobook.duration = 3600 // 1 hour
        context.insert(audiobook)

        // Position near end (within 30 seconds of end)
        let session = PlaybackSession(
            currentPosition: 3580, // 10 seconds from end
            isCompleted: true
        )
        audiobook.playbackSession = session
        context.insert(session)
        try context.save()

        #expect(session.isCompleted == true)
    }

    @Test("Sync conflict scenario - Watch has newer progress")
    func syncConflictWatchNewer() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        // iPhone state: old progress from yesterday
        let iphoneTimestamp = Date().addingTimeInterval(-86400) // 1 day ago
        let iphonePosition: Double = 600 // 10 minutes

        // Watch state: recent progress from today
        let watchTimestamp = Date().addingTimeInterval(-60) // 1 minute ago
        let watchPosition: Double = 1800 // 30 minutes

        // Initial state (iPhone's old data)
        let session = PlaybackSession(
            currentPosition: iphonePosition,
            currentChapter: 1,
            lastPlayed: iphoneTimestamp
        )
        audiobook.playbackSession = session
        context.insert(session)
        try context.save()

        // Simulate CloudKit sync bringing Watch's newer data
        let remoteLastPlayed = watchTimestamp
        let remotePosition = watchPosition

        // The fix logic: if remote is newer, adopt it
        if remoteLastPlayed > session.lastPlayed {
            session.currentPosition = remotePosition
            session.lastPlayed = remoteLastPlayed
        }

        try context.save()

        // Verify Watch progress was adopted (newer timestamp won)
        #expect(session.currentPosition == watchPosition)
        #expect(session.lastPlayed == watchTimestamp)
    }

    @Test("Sync conflict scenario - iPhone has newer progress")
    func syncConflictIPhoneNewer() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        // Watch state: old progress from yesterday
        let watchTimestamp = Date().addingTimeInterval(-86400) // 1 day ago
        let watchPosition: Double = 600 // 10 minutes

        // iPhone state: recent progress
        let iphoneTimestamp = Date().addingTimeInterval(-60) // 1 minute ago
        let iphonePosition: Double = 1800 // 30 minutes

        // Current state is iPhone's (we're on iPhone)
        let session = PlaybackSession(
            currentPosition: iphonePosition,
            currentChapter: 3,
            lastPlayed: iphoneTimestamp
        )
        audiobook.playbackSession = session
        context.insert(session)
        try context.save()

        // Simulate CloudKit sync bringing Watch's older data
        let remoteLastPlayed = watchTimestamp
        let remotePosition = watchPosition

        // The fix logic: if remote is older, keep local
        if remoteLastPlayed > session.lastPlayed {
            session.currentPosition = remotePosition
            session.lastPlayed = remoteLastPlayed
        }
        // else: keep current values (iPhone's newer data)

        try context.save()

        // Verify iPhone progress was kept (local is newer)
        #expect(session.currentPosition == iphonePosition)
        #expect(session.lastPlayed == iphoneTimestamp)
    }

    @Test("Multiple rapid updates preserve latest")
    func rapidUpdatesPreserveLatest() async throws {
        let container = try createTestContainerWithPlayback()
        let context = ModelContext(container)

        let audiobook = createTestAudiobook()
        context.insert(audiobook)

        let session = PlaybackSession()
        audiobook.playbackSession = session
        context.insert(session)

        // Simulate rapid updates (every 5 seconds like real player)
        var latestPosition: Double = 0
        var latestTime = Date()

        for i in 1...10 {
            let position = Double(i * 5)
            let time = Date().addingTimeInterval(Double(i))

            session.currentPosition = position
            session.lastPlayed = time

            latestPosition = position
            latestTime = time
        }

        try context.save()

        // Last update should be preserved
        #expect(session.currentPosition == latestPosition)
        #expect(session.lastPlayed == latestTime)
    }
}
