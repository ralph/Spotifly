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

    var isLoading = false
    var errorMessage: String?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Device Loading

    /// Load available Spotify Connect devices
    func loadDevices(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
            let devices = response.devices.map { Device(from: $0) }
            store.upsertDevices(devices)
        } catch let error as SpotifyAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "devices.error.failed_to_load")
        }

        isLoading = false
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device
    func transferPlayback(to device: Device, accessToken: String) async {
        do {
            try await SpotifyAPI.transferPlayback(
                accessToken: accessToken,
                deviceId: device.id,
                play: true,
            )

            // Reload devices to update active state
            await loadDevices(accessToken: accessToken)
        } catch let error as SpotifyAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "devices.error.failed_to_transfer")
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
