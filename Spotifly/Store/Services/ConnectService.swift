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
    private let deviceService: DeviceService
    private let maxSyncFailuresBeforeDeactivate = 3

    init(store: AppStore, deviceService: DeviceService) {
        self.store = store
        self.deviceService = deviceService
    }

    // MARK: - Connect Activation

    /// Activate Spotify Connect mode and start periodic sync
    func activateConnect(deviceId: String, deviceName: String?, accessToken: String) {
        #if DEBUG
            print("[ConnectService] activateConnect: deviceId=\(deviceId), deviceName=\(deviceName ?? "nil")")
        #endif
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
        store.connectVolumeUpdateTask?.cancel()

        // Debounce volume updates (150ms)
        store.connectVolumeUpdateTask = Task {
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
        store.connectConsecutiveSyncFailures = 0

        store.connectSyncTask = Task {
            // Initial delay to allow transfer to complete
            try? await Task.sleep(for: .milliseconds(500))

            while !Task.isCancelled {
                await syncPlaybackState(accessToken: accessToken)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopSyncTask() {
        store.connectSyncTask?.cancel()
        store.connectSyncTask = nil
    }

    private func syncPlaybackState(accessToken: String) async {
        do {
            guard let state = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken) else {
                store.connectConsecutiveSyncFailures += 1
                #if DEBUG
                    print("[ConnectService] syncPlaybackState: no playback state (failure \(store.connectConsecutiveSyncFailures)/\(maxSyncFailuresBeforeDeactivate))")
                #endif
                if store.connectConsecutiveSyncFailures >= maxSyncFailuresBeforeDeactivate {
                    #if DEBUG
                        print("[ConnectService] too many failures, deactivating")
                    #endif
                    deactivateConnect()
                }
                return
            }

            // Reset failure counter on success
            store.connectConsecutiveSyncFailures = 0

            #if DEBUG
                print("[ConnectService] sync: playing=\(state.isPlaying), progress=\(state.progressMs)ms, volume=\(state.device?.volumePercent ?? -1)%")
            #endif

            store.updateFromConnectState(state)

            // Update device info if changed and refresh device list
            if let device = state.device {
                if device.id != store.spotifyConnectDeviceId {
                    store.spotifyConnectDeviceId = device.id
                    store.spotifyConnectDeviceName = device.name
                    // Refresh device list so UI shows correct active device
                    await deviceService.loadDevices(accessToken: accessToken)
                }
            }
        } catch {
            store.connectConsecutiveSyncFailures += 1
            #if DEBUG
                print("[ConnectService] syncPlaybackState error (failure \(store.connectConsecutiveSyncFailures)/\(maxSyncFailuresBeforeDeactivate)): \(error)")
            #endif
            if store.connectConsecutiveSyncFailures >= maxSyncFailuresBeforeDeactivate {
                deactivateConnect()
            }
        }
    }
}
