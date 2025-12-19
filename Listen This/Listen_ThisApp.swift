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
    
    #if os(iOS)
    // Watch Connectivity Manager
    @State private var watchConnectivity = iOSWatchConnectivityManager.shared
    #endif
    
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
                #if os(iOS)
                .environment(watchConnectivity)
                #endif
                .onAppear {
                    #if os(iOS)
                    // Configure Watch Connectivity with model context
                    if let context = modelContainer.mainContext as? ModelContext {
                        watchConnectivity.configure(modelContext: context)
                    }
                    
                    // Check for outstanding transfers
                    watchConnectivity.checkOutstandingTransfers()
                    
                    // Log WatchConnectivity status for debugging
                    print("📱 [iOS App] Launched")
                    print("📱 [iOS App] Session state: \(WCSession.default.activationState.rawValue)")
                    print("📱 [iOS App] Watch paired: \(WCSession.default.isPaired)")
                    print("📱 [iOS App] Watch app installed: \(WCSession.default.isWatchAppInstalled)")
                    print("📱 [iOS App] Reachable: \(WCSession.default.isReachable)")
                    
                    if let session = WCSession.default as WCSession?, session.activationState == .activated {
                        let outstanding = session.outstandingFileTransfers
                        print("📱 [iOS App] Outstanding file transfers: \(outstanding.count)")
                        for transfer in outstanding {
                            if let title = transfer.file.metadata?["title"] as? String {
                                print("   - \(title) (transferring: \(transfer.isTransferring))")
                            }
                        }
                    }
                    #endif
                }
        }
        .modelContainer(modelContainer)
    }
}

