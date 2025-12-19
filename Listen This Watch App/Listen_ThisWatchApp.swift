//
//  Listen_ThisApp.swift
//  Listen This Watch App
//
//  Created by Eetu Sutinen on 14.12.2025.
//

import SwiftUI
import SwiftData
import WatchConnectivity
import Combine

// Disambiguate WatchConnectivityManager for Watch target
typealias WatchManager = WatchConnectivityManager

@main
struct Listen_ThisWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self) var extensionDelegate
    @State private var watchConnectivityManager: WatchManager = .shared
    @State private var transferCheckTimer: Timer?

    let modelContainer: ModelContainer
    
    init() {
        do {
            let schema = Schema([
                Audiobook.self,
                Chapter.self,
                PlaybackSession.self,
                CacheEntry.self
            ])
            
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.com.anarkisti.Listen-This")
            )
            
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            WatchLibraryView()
                .environment(watchConnectivityManager)
                .onAppear {
                    // Configure the connectivity manager with model context
                    watchConnectivityManager.configure(modelContext: modelContainer.mainContext)
                    
                    // Check for any ongoing or pending transfers
                    watchConnectivityManager.checkPendingTransfers()
                    
                    print("⌚ [Watch App] Launched")
                    print("⌚ [Watch App] Session state: \(WCSession.default.activationState.rawValue)")
                    print("⌚ [Watch App] Reachable: \(WCSession.default.isReachable)")
                    
                    // Start periodic transfer status logging
                    startTransferMonitoring()
                }
                .onDisappear {
                    stopTransferMonitoring()
                }
        }
        .modelContainer(modelContainer)
    }
    
    // MARK: - Transfer Monitoring
    
    private func startTransferMonitoring() {
        // Log transfer status every 10 seconds
        transferCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                let activeCount = watchConnectivityManager.activeTransfers.count
                
                if activeCount > 0 {
                    print("⌚ [Watch App] Active transfers check: \(activeCount)")
                    for (id, transfer) in watchConnectivityManager.activeTransfers {
                        print("   - \(id): \(transfer.progressPercentage)% (\(transfer.progressText))")
                    }
                }
                
                // Check WCSession status
                if WCSession.default.hasContentPending {
                    print("⌚ [Watch App] WCSession has content pending")
                }
            }
        }
    }
    
    private func stopTransferMonitoring() {
        transferCheckTimer?.invalidate()
        transferCheckTimer = nil
    }
}
