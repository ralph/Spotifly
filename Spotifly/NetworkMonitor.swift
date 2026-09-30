//
//  NetworkMonitor.swift
//  Spotifly
//
//  Tells views when the network has come back.
//

import Foundation
import Network

/// Counts the network's returns, for work that failed or stalled while it was away and that
/// nothing else would start again: artwork (`RetryingAsyncImage`) and a page's failed load
/// (`InlineLoadError`).
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Goes up each time the network is usable again after it was not.
    private(set) var returns = 0

    /// Whether the last path was usable. Starts true, so the first report, which describes the
    /// path as it is at launch, counts only if it is a way back from being offline.
    @ObservationIgnored private var satisfied = true

    private init() {
        Task {
            for await path in NWPathMonitor() {
                update(satisfied: path.status == .satisfied)
            }
        }
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
