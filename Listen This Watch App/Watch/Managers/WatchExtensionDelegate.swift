//
//  WatchExtensionDelegate.swift
//  Listen This Watch App
//
//  Handles background tasks for Watch Connectivity file transfers
//  Uses KVO-based completion pattern from Apple's TransferringDataWithWatchConnectivity sample
//

import Foundation
import WatchKit
import WatchConnectivity

/// Extension delegate that handles background tasks for file transfers
/// Critical for receiving files when app is not in foreground
class WatchExtensionDelegate: NSObject, WKExtensionDelegate {

    // MARK: - Background Task Handling

    // Hold KVO observers for the extension's lifetime
    // These observe WCSession state to know when to complete background tasks
    private var activationStateObservation: NSKeyValueObservation?
    private var hasContentPendingObservation: NSKeyValueObservation?

    // Store Watch Connectivity background tasks until transfer completes
    // CRITICAL: Do NOT complete these tasks until hasContentPending == false
    private var wcBackgroundTasks = [WKWatchConnectivityRefreshBackgroundTask]()

    override init() {
        super.init()

        guard WCSession.isSupported() else { return }

        // CRITICAL: Apps must complete WKWatchConnectivityRefreshBackgroundTask properly.
        // Completing tasks too early causes transfers to fail and consumes background runtime budget.
        // Complete tasks only when:
        // 1. Session activationState == .activated AND
        // 2. hasContentPending == false (meaning all pending data is received)
        //
        // Use KVO to observe both properties and complete tasks when conditions are met.

        activationStateObservation = WCSession.default.observe(\.activationState) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.completeBackgroundTasks()
            }
        }

        hasContentPendingObservation = WCSession.default.observe(\.hasContentPending) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.completeBackgroundTasks()
            }
        }
    }

    /// Handle background tasks, including Watch Connectivity session tasks
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let wcTask as WKWatchConnectivityRefreshBackgroundTask:
                // Handle Watch Connectivity background refresh

                // CRITICAL: Store the task, do NOT complete it yet
                // The task will be completed when hasContentPending becomes false
                wcBackgroundTasks.append(wcTask)

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                // Handle snapshot refresh - complete immediately
                print("[ExtensionDelegate] Handling snapshot refresh task")
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: true,
                    estimatedSnapshotExpiration: Date.distantFuture,
                    userInfo: nil
                )

            case let appRefreshTask as WKApplicationRefreshBackgroundTask:
                // Handle app refresh - complete immediately
                print("[ExtensionDelegate] Handling app refresh task")
                appRefreshTask.setTaskCompletedWithSnapshot(false)

            default:
                // Handle any other background task - complete immediately
                print("⚠️ [ExtensionDelegate] Unknown background task type: \(type(of: task)), completing immediately")
                task.setTaskCompletedWithSnapshot(false)
            }
        }

        // Try to complete background tasks if conditions are already met
        // This handles the case where hasContentPending flips to false before we store the tasks
        completeBackgroundTasks()
    }

    /// Complete background tasks when WCSession is ready and has no pending content
    /// CRITICAL: This is called via KVO when activationState or hasContentPending changes
    private func completeBackgroundTasks() {
        guard !wcBackgroundTasks.isEmpty else { return }

        // CRITICAL: Only complete when session is activated AND no content is pending
        // hasContentPending == false means all data has been received and processed
        guard WCSession.default.activationState == .activated,
              WCSession.default.hasContentPending == false else {
            print("[ExtensionDelegate] Waiting for session (activated: \(WCSession.default.activationState == .activated), pending: \(WCSession.default.hasContentPending))")
            return
        }

        // Complete all stored tasks
        wcBackgroundTasks.forEach { $0.setTaskCompletedWithSnapshot(false) }

        // Schedule a snapshot refresh to update UI
        let date = Date(timeIntervalSinceNow: 1)
        WKApplication.shared().scheduleSnapshotRefresh(withPreferredDate: date, userInfo: nil) { error in
            if let error = error {
                print("⚠️ [ExtensionDelegate] Snapshot refresh error: \(error)")
            }
        }

        wcBackgroundTasks.removeAll()
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching() {
        // Activate WCSession as early as possible to save background runtime budget
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = WatchConnectivityManager.shared
            session.activate()
        }
    }

    func applicationDidBecomeActive() {
        print("[ExtensionDelegate] Watch app did become active")
    }

    func applicationWillResignActive() {
        print("[ExtensionDelegate] Watch app will resign active")
    }

    func applicationDidEnterBackground() {
        print("[ExtensionDelegate] Watch app entered background")
    }

    func applicationWillEnterForeground() {
        print("[ExtensionDelegate] Watch app entering foreground")
    }
}
