//
//  NetworkStatusMonitor.swift
//  Listen This
//
//  Whether this device has a network path, for showing an offline state.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkStatusMonitor {

    static let shared = NetworkStatusMonitor()

    /// Optimistic until the first path arrives, so nothing flashes "offline"
    /// at launch.
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                NetworkStatusMonitor.shared.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkStatusMonitor"))
    }
}
