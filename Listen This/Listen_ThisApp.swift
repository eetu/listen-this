//
//  Listen_ThisApp.swift
//  Listen This
//
//  Created by Eetu Sutinen on 13.12.2025.
//

import SwiftUI
import SwiftData

@main
struct Listen_ThisApp: App {
    // MARK: - SwiftData Model Container
    
    let modelContainer: ModelContainer
    
    init() {
        do {
            // Configure the model container with all models
            let schema = Schema([
                Audiobook.self,
                Chapter.self,
                PlaybackSession.self,
                CacheEntry.self
            ])
            
            // Try CloudKit first, fall back to local-only if it fails
            let modelConfiguration: ModelConfiguration
            
            // In release, require CloudKit
            modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.anarkisti.Listen-This")
            )
            
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            // Provide more helpful error message
            print("ModelContainer initialization error: \(error)")
            print("Error details: \(error.localizedDescription)")
            fatalError("Could not initialize ModelContainer. See console for details.")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
