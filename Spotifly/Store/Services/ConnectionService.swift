//
//  ConnectionService.swift
//  Spotifly
//
//  Service to sync librespot connection state with AppStore.
//  Converts the client's LibrespotConnectionState to SpotifyConnection (app) at the boundary.
//

import Combine
import Foundation

@MainActor
@Observable
final class ConnectionService {
    private let store: AppStore
    private var connectionStateSubscription: AnyCancellable?

    init(store: AppStore) {
        self.store = store
    }

    /// Starts observing connection state. Call once, from the view that kept this instance.
    ///
    /// Deliberately not done in `init`: SwiftUI runs a View's `init` repeatedly and keeps
    /// only the first `State(initialValue:)`, so a subscription made there outlives the
    /// object's usefulness and keeps writing into an `AppStore` nothing reads.
    ///
    /// Idempotent — the guard reads the subscription it protects.
    func activate() {
        guard connectionStateSubscription == nil else { return }
        recordActivation(self)

        connectionStateSubscription = SpotifyPlayer.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.store.setConnection(Self.convert(state))
            }

        // The subscription delivers on a later main-actor hop; this reads the client's
        // current state directly, so the store holds it before activation returns.
        store.setConnection(Self.convert(SpotifyPlayer.getConnectionState()))
    }

    /// Convert the client's state to the app-level connection model
    private static func convert(_ state: LibrespotConnectionState?) -> SpotifyConnection? {
        guard let state else { return nil }

        let connectedSince: Date? = if let ms = state.connectedSinceMs {
            Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            nil
        }

        return SpotifyConnection(
            deviceId: state.deviceId,
            deviceName: state.deviceName,
            isConnected: state.sessionConnected,
            connectionId: state.sessionConnectionId,
            connectedSince: connectedSince,
            spircReady: state.spircReady,
            reconnectAttempts: state.reconnectAttempt,
            lastError: state.sessionConnected ? nil : state.lastError,
        )
    }
}
