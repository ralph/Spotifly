//
//  DevicesViewModel.swift
//  Spotifly
//
//  View model for managing Spotify Connect devices
//

import Foundation

@MainActor
@Observable
final class DevicesViewModel {
    var devices: [SpotifyDevice] = []
    var isLoading = false
    var errorMessage: String?

    func loadDevices(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
            devices = response.devices
        } catch let error as SpotifyAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "devices.error.failed_to_load")
        }

        isLoading = false
    }

    func transferPlayback(to device: SpotifyDevice, accessToken: String) async {
        do {
            try await SpotifyAPI.transferPlayback(accessToken: accessToken, deviceId: device.id, play: true)

            // Reload devices to update active state
            await loadDevices(accessToken: accessToken)
        } catch let error as SpotifyAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "devices.error.failed_to_transfer")
        }
    }

    func deviceIcon(for type: String) -> String {
        switch type.lowercased() {
        case "computer":
            return "desktopcomputer"
        case "smartphone":
            return "iphone"
        case "speaker":
            return "hifispeaker"
        case "tv":
            return "tv"
        case "avr", "stb":
            return "appletv"
        case "automobile":
            return "car"
        default:
            return "speaker.wave.2"
        }
    }
}
