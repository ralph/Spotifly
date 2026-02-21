//
//  ConnectionService.swift
//  Spotifly
//
//  Service to sync librespot connection state with AppStore.
//  Converts LibrespotConnectionState (FFI) to SpotifyConnection (app) at the boundary.
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
        setupConnectionStateSubscription()
        refreshConnectionState()
    }

    /// Subscribe to connection state updates from SpotifyPlayer
    private func setupConnectionStateSubscription() {
        connectionStateSubscription = SpotifyPlayer.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.store.setConnection(Self.convert(state))
            }
    }

    /// Manually refresh connection state from SpotifyPlayer
    func refreshConnectionState() {
        let state = SpotifyPlayer.getConnectionState()
        store.setConnection(Self.convert(state))
    }

    /// Convert FFI state to app-level connection model
    private static func convert(_ state: LibrespotConnectionState?) -> SpotifyConnection? {
        guard let state else { return nil }

        let connectedSince: Date? = if let ms = state.connectedSinceMs {
            Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            nil
        }

        let playbackContinuitySince: Date? = if let ms = state.playbackContinuitySinceMs {
            Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            nil
        }

        let lastReconnectCompletedAt: Date? = if let ms = state.lastReconnectCompletedMs {
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
            reconnectPhase: state.reconnectPhase,
            reconnectTrigger: state.reconnectTrigger,
            reconnectAttempts: state.reconnectAttempt,
            reconnectTotalStarted: state.reconnectTotalStarted,
            reconnectTotalSucceeded: state.reconnectTotalSucceeded,
            reconnectTotalFailed: state.reconnectTotalFailed,
            reconnectTotalHardFallbacks: state.reconnectTotalHardFallbacks,
            audioInterruptionsTotal: state.audioInterruptionsTotal,
            playbackContinuitySince: playbackContinuitySince,
            lastReconnectTrigger: state.lastReconnectTrigger,
            lastReconnectCompletedAt: lastReconnectCompletedAt,
            lastReconnectSucceeded: state.lastReconnectSucceeded,
            lastReconnectAttempts: state.lastReconnectAttempts,
            lastReconnectUsedHardFallback: state.lastReconnectUsedHardFallback,
            lastReconnectTimeToReadyMs: state.lastReconnectTimeToReadyMs,
            lastReconnectTimeToFirstPlayingMs: state.lastReconnectTimeToFirstPlayingMs,
            lastReconnectFailureReason: state.lastReconnectFailureReason,
            lastError: state.lastError,
        )
    }
}
