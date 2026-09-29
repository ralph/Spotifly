//
//  NetworkMonitor.swift
//  Spotifly
//
//  Tells views when the network has come back.
//

import Foundation
import Network

/// Counts the network's returns, for work that failed or stalled while it was away and that
/// nothing else would start again, such as artwork; see `RetryingAsyncImage`.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Goes up each time the network is usable again after it was not.
    private(set) var returns = 0

    /// Whether the last path was usable. Starts true, so the first report, which describes the
    /// path as it is at launch, counts only if it is a way back from being offline.
    private var satisfied = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.update(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    /// For tests, which cannot take the network away.
    init(satisfied: Bool) {
        self.satisfied = satisfied
    }

    func update(satisfied now: Bool) {
        if now, !satisfied {
            returns += 1
            debugLog("NetworkMonitor", "The network is back")
        }
        satisfied = now
    }
}
