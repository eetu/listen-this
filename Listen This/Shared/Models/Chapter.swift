//
//  Chapter.swift
//  listen this
//
//  Created on 13.12.2025.
//

import Foundation
import SwiftData

@Model
final class Chapter {
    var id: UUID = UUID.init()
    var index: Int = 0
    var title: String = ""
    var startTime: Double = 0  // Start time in seconds
    var duration: Double = 0   // Chapter duration in seconds
    
    @Relationship var audiobook: Audiobook?
    
    init(
        id: UUID = UUID(),
        index: Int = 0,
        title: String = "",
        startTime: Double = 0,
        duration: Double = 0
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.startTime = startTime
        self.duration = duration
    }
}
