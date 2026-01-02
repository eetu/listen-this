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
            // All models in a single schema with CloudKit sync
            // Note: CacheEntry will sync via CloudKit, but this is acceptable
            // because the relationship is optional and device-specific cleanup
            // won't affect other devices' ability to maintain their own cache entries
            let schema = Schema([
                Audiobook.self,
                Chapter.self,
                PlaybackSession.self,
                CacheEntry.self,
                UserSettings.self
            ])

            let modelConfiguration = ModelConfiguration(
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
                    // Configure SettingsManager with model context
                    SettingsManager.shared.configure(modelContext: modelContainer.mainContext)

                    #if os(iOS)
                    // Configure Watch Connectivity with model context
                    watchConnectivity.configure(modelContext: modelContainer.mainContext)
                    
                    // Check for outstanding transfers
                    watchConnectivity.checkOutstandingTransfers()
                    
                    if let session = WCSession.default as WCSession?, session.activationState == .activated {
                        let outstanding = session.outstandingFileTransfers
                        print("[iOS App] Outstanding file transfers: \(outstanding.count)")
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

