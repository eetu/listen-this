//
//  Listen_ThisApp.swift
//  Listen This
//

import OSLog
import SwiftData
import SwiftUI

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

    @Environment(\.scenePhase) private var scenePhase

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
                UserSettings.self,
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
            AppLogger.general.error(
                "ModelContainer initialization error: \(error.localizedDescription)")
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

                        if let session = WCSession.default as WCSession?,
                            session.activationState == .activated
                        {
                            let outstanding = session.outstandingFileTransfers
                            AppLogger.watchConnectivity.debug(
                                "Outstanding file transfers: \(outstanding.count)")
                            for transfer in outstanding {
                                if let title = transfer.file.metadata?["title"] as? String {
                                    AppLogger.watchConnectivity.debug(
                                        "- \(title) (transferring: \(transfer.isTransferring))")
                                }
                            }
                        }
                    #endif
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
        }
    }

    // MARK: - Scene Phase Handling

    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        if newPhase == .background {
            // App entering background - save playback state
            AppLogger.general.debug("Entering background, saving playback state")

            Task { @MainActor in
                // Save context to ensure latest data is persisted
                try? modelContainer.mainContext.save()

                #if os(iOS)
                    // If iPhone becomes reachable later, sync will happen automatically
                    // via sessionReachabilityDidChange
                    if watchConnectivity.isReachable {
                        AppLogger.watchConnectivity.debug(
                            "iPhone is reachable, will sync on reconnection")
                    }
                #endif
            }
        } else if newPhase == .active && oldPhase == .background {
            // App becoming active from background
            AppLogger.general.debug("Becoming active from background")

            #if os(iOS)
                // Check if Watch Connectivity became reachable while we were in background
                if watchConnectivity.isReachable {
                    AppLogger.watchConnectivity.debug(
                        "iPhone is reachable after background, sync will trigger automatically")
                }
            #endif
        }
    }
}
