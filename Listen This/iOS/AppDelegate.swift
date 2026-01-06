//
//  AppDelegate.swift
//  Listen This
//
//  Handles background URLSession completion events for CloudKit chunk transfers
//

import OSLog
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = AppLogger.cloudKit

    // Store completion handler to be called by URLSession delegate
    static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Background URLSession with identifier '\(identifier)' has events to deliver")

        // Store the completion handler
        // The CloudKitChunkedTransferManager's URLSession delegate will call this
        // when urlSessionDidFinishEvents(forBackgroundURLSession:) is invoked
        AppDelegate.backgroundSessionCompletionHandler = completionHandler

        logger.info(
            "Stored background session completion handler, waiting for URLSession to finish events")
    }
}
