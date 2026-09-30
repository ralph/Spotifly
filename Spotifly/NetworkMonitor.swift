//
//  NetworkMonitor.swift
//  Spotifly
//
//  Tells views when the network has come back.
//

import Foundation
import Network
import SwiftUI

/// Counts the network's returns, for work that failed or stalled while it was away and that
/// nothing else would start again: artwork (`RetryingAsyncImage`), and the loads that show an
/// error with Try again (`retryingWhenNetworkReturns`).
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

extension View {
    /// Runs `retry` each time the network comes back while `failed` holds: a load that failed
    /// while the network was away is asked for again when it returns, rather than waiting for a
    /// Try again nobody presses.
    func retryingWhenNetworkReturns(if failed: Bool, _ retry: @escaping () async -> Void) -> some View {
        modifier(RetryWhenNetworkReturns(failed: failed, retry: retry))
    }
}

private struct RetryWhenNetworkReturns: ViewModifier {
    let failed: Bool
    let retry: () async -> Void

    private let network = NetworkMonitor.shared

    func body(content: Content) -> some View {
        content.onChange(of: network.returns) {
            if failed {
                Task { await retry() }
            }
        }
    }
}
