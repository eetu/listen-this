//
//  Listen_ThisApp.swift
//  Listen This
//
//  Created by Eetu Sutinen on 13.12.2025.
//

import SwiftUI
import SwiftData

#if os(iOS)
import WatchConnectivity
#endif

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
            
            let container = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            
            modelContainer = container
            
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
                .onAppear {
                    #if os(iOS)
                    // Log WatchConnectivity status for debugging
                    print("📱 [iOS App] View appeared")
                    print("📱 [iOS App] Session state: \(WCSession.default.activationState.rawValue)")
                    print("📱 [iOS App] Watch paired: \(WCSession.default.isPaired)")
                    print("📱 [iOS App] Watch app installed: \(WCSession.default.isWatchAppInstalled)")
                    print("📱 [iOS App] Reachable: \(WCSession.default.isReachable)")
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }
}

