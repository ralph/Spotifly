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

            // Track active device ID
            if let activeDevice = devices.first(where: { $0.isActive }) {
                store.activeDeviceId = activeDevice.id
            } else {
                store.activeDeviceId = nil
            }
        } catch let error as SpotifyAPIError {
            store.devicesErrorMessage = error.localizedDescription
        } catch {
            store.devicesErrorMessage = String(localized: "speakers.error.failed_to_load")
        }

        store.devicesIsLoading = false
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device
    /// Uses native Spotify Connect protocol for seamless handoff.
    /// Returns true if transfer succeeded (caller should activate Connect mode)
    func transferPlayback(to device: Device, accessToken: String) async -> Bool {
        do {
            try SpotifyPlayer.transferPlayback(to: device.id)

            // Reload devices to update active state
            await loadDevices(accessToken: accessToken)

            return true
        } catch {
            store.devicesErrorMessage = String(localized: "speakers.error.failed_to_transfer")
            return false
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
