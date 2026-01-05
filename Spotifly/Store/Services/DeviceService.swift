//
//  DeviceService.swift
//  Spotifly
//
//  Service for Spotify Connect device operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class DeviceService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Device Loading

    /// Load available Spotify Connect devices
    func loadDevices(accessToken: String) async {
        store.devicesIsLoading = true
        store.devicesErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
            let devices = response.devices.map { Device(from: $0) }
            store.upsertDevices(devices)
        } catch let error as SpotifyAPIError {
            store.devicesErrorMessage = error.localizedDescription
        } catch {
            store.devicesErrorMessage = String(localized: "devices.error.failed_to_load")
        }

        store.devicesIsLoading = false
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device with queue sync
    /// Returns true if transfer succeeded (caller should activate Connect mode)
    func transferPlayback(to device: Device, accessToken: String) async -> Bool {
        do {
            // Get current queue and position from librespot
            let currentIndex = SpotifyPlayer.currentIndex
            let queueLength = SpotifyPlayer.queueLength
            let positionMs = Int(SpotifyPlayer.positionMs)

            // Build track URIs from current position onwards
            var trackUris: [String] = []
            for i in currentIndex ..< queueLength {
                if let uri = SpotifyPlayer.queueUri(at: i) {
                    trackUris.append(uri)
                }
            }

            if !trackUris.isEmpty {
                // Start playback with queue and position (preserves queue)
                try await SpotifyAPI.startPlayback(
                    accessToken: accessToken,
                    deviceId: device.id,
                    trackUris: trackUris,
                    positionMs: positionMs,
                )
            } else {
                // No queue - just transfer playback
                try await SpotifyAPI.transferPlayback(
                    accessToken: accessToken,
                    deviceId: device.id,
                    play: true,
                )
            }

            // Pause local playback
            SpotifyPlayer.pause()

            // Reload devices to update active state
            await loadDevices(accessToken: accessToken)

            return true
        } catch let error as SpotifyAPIError {
            store.devicesErrorMessage = error.localizedDescription
            return false
        } catch {
            store.devicesErrorMessage = String(localized: "devices.error.failed_to_transfer")
            return false
        }
    }

    /// Load playback state from Spotify API
    func loadPlaybackState(accessToken: String) async -> PlaybackState? {
        do {
            return try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Get appropriate icon name for device type
    func deviceIcon(for type: String) -> String {
        switch type.lowercased() {
        case "computer":
            "desktopcomputer"
        case "smartphone":
            "iphone"
        case "speaker":
            "hifispeaker"
        case "tv":
            "tv"
        case "avr", "stb":
            "appletv"
        case "automobile":
            "car"
        default:
            "speaker.wave.2"
        }
    }
}
