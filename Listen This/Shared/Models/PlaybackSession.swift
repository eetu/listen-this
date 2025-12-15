//
//  PlaybackSession.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation
import SwiftData

@Model
final class PlaybackSession {
    var id: UUID = UUID.init()
    var currentPosition: Double = 0  // Current playback position in seconds
    var currentChapter: Int = 0      // Current chapter index
    var playbackRate: Double = 1.0     // Playback speed (0.5 - 2.0)
    var lastSynced: Date = Date()        // Last CloudKit sync
    var lastPlayed: Date = Date()        // Last playback activity
    var progressPercentage: Double = 0  // 0.0 - 100.0
    var isCompleted: Bool = false
    
    @Relationship var audiobook: Audiobook?
    
    init(
        id: UUID = UUID(),
        currentPosition: Double = 0,
        currentChapter: Int = 0,
        playbackRate: Double = 1.0,
        lastSynced: Date = Date(),
        lastPlayed: Date = Date(),
        progressPercentage: Double = 0,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.currentPosition = currentPosition
        self.currentChapter = currentChapter
        self.playbackRate = playbackRate
        self.lastSynced = lastSynced
        self.lastPlayed = lastPlayed
        self.progressPercentage = progressPercentage
        self.isCompleted = isCompleted
    }
}
