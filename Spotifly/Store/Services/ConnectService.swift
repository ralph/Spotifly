//
//  ConnectService.swift
//  Spotifly
//
//  Service for Spotify Connect operations.
//  Handles remote playback control and periodic sync.
//

import Foundation

@MainActor
@Observable
final class ConnectService {
    private let store: AppStore
    private var syncTask: Task<Void, Never>?
    private var volumeUpdateTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Connect Activation

    /// Activate Spotify Connect mode and start periodic sync
    func activateConnect(deviceId: String, deviceName: String?, accessToken: String) {
        store.activateSpotifyConnect(deviceId: deviceId, deviceName: deviceName)
        startSyncTask(accessToken: accessToken)
    }

    /// Deactivate Spotify Connect mode and stop sync
    func deactivateConnect() {
        stopSyncTask()
        store.deactivateSpotifyConnect()
    }

    /// Check if playback is active on another device and sync if so
    func checkAndSyncRemotePlayback(accessToken: String) async {
        do {
            guard let state = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken) else {
                return
            }

            // If playing on a device that's not this app, activate Connect mode
            if let device = state.device, state.isPlaying {
                store.activateSpotifyConnect(
                    deviceId: device.id,
                    deviceName: device.name,
                )
                store.updateFromConnectState(state)
                startSyncTask(accessToken: accessToken)
            }
        } catch {
            // Ignore errors - user might not have any active playback
        }
    }

    // MARK: - Playback Control

    /// Pause playback on the active Spotify Connect device
    func pause(accessToken: String) async {
        do {
            try await SpotifyAPI.pausePlayback(accessToken: accessToken)
            store.isPlaying = false
        } catch {
            store.playbackError = error.localizedDescription
        }
    }

    /// Resume playback on the active Spotify Connect device
    func resume(accessToken: String) async {
        do {
            try await SpotifyAPI.resumePlayback(accessToken: accessToken)
            store.isPlaying = true
        } catch {
            store.playbackError = error.localizedDescription
        }
    }

    /// Skip to the next track
    func skipToNext(accessToken: String) async {
        do {
            try await SpotifyAPI.skipToNext(accessToken: accessToken)
            // State will be updated by sync task
        } catch {
            store.playbackError = error.localizedDescription
        }
    }

    /// Skip to the previous track
    func skipToPrevious(accessToken: String) async {
        do {
            try await SpotifyAPI.skipToPrevious(accessToken: accessToken)
            // State will be updated by sync task
        } catch {
            store.playbackError = error.localizedDescription
        }
    }

    /// Seek to a position in the current track
    func seek(to positionMs: Int, accessToken: String) async {
        do {
            try await SpotifyAPI.seekToPosition(accessToken: accessToken, positionMs: positionMs)
            store.currentPositionMs = UInt32(positionMs)
        } catch {
            store.playbackError = error.localizedDescription
        }
    }

    // MARK: - Volume Control

    /// Set volume on the active Spotify Connect device (debounced)
    func setVolume(_ volume: Double, accessToken: String) {
        store.spotifyConnectVolume = volume

        // Cancel any pending volume update
        volumeUpdateTask?.cancel()

        // Debounce volume updates (150ms)
        volumeUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }

            let volumePercent = Int(volume)
            do {
                try await SpotifyAPI.setVolume(
                    accessToken: accessToken,
                    volumePercent: volumePercent,
                    deviceId: store.spotifyConnectDeviceId,
                )
            } catch {
                // Ignore volume errors - device might not support volume control
            }
        }
    }

    // MARK: - Private Sync Methods

    private func startSyncTask(accessToken: String) {
        stopSyncTask()

        syncTask = Task {
            while !Task.isCancelled {
                await syncPlaybackState(accessToken: accessToken)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopSyncTask() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func syncPlaybackState(accessToken: String) async {
        do {
            guard let state = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken) else {
                // No active playback - deactivate Connect
                deactivateConnect()
                return
            }

            store.updateFromConnectState(state)

            // Update device info if changed
            if let device = state.device {
                if device.id != store.spotifyConnectDeviceId {
                    store.spotifyConnectDeviceId = device.id
                    store.spotifyConnectDeviceName = device.name
                }
            }
        } catch {
            // On error, keep current state - transient network issues shouldn't deactivate
        }
    }
}
