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

    // Playback state
    var playbackState: PlaybackState?
    var activeDevice: SpotifyDevice? {
        playbackState?.device ?? devices.first(where: { $0.isActive })
    }

    func loadDevices(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        // Fetch devices and playback state separately so one failure doesn't block the other
        do {
            let devicesResponse = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
            devices = devicesResponse.devices
        } catch let error as SpotifyAPIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = String(localized: "devices.error.failed_to_load")
        }

        // Fetch playback state (don't fail if this errors)
        do {
            playbackState = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken)
        } catch {
            // Playback state is optional, don't show error
            playbackState = nil
        }

        isLoading = false
    }

    func transferPlayback(to device: SpotifyDevice, accessToken: String) async {
        do {
            // Get current track and queue from librespot
            let currentIndex = SpotifyPlayer.currentIndex
            let queueLength = SpotifyPlayer.queueLength
            let positionMs = Int(SpotifyPlayer.positionMs)

            // Build array of track URIs from current position to end of queue
            var trackUris: [String] = []
            for i in currentIndex ..< queueLength {
                if let uri = SpotifyPlayer.queueUri(at: i) {
                    trackUris.append(uri)
                }
            }

            if !trackUris.isEmpty {
                // Start playback on the Spotify Connect device with current track and position
                try await SpotifyAPI.startPlayback(
                    accessToken: accessToken,
                    deviceId: device.id,
                    trackUris: trackUris,
                    positionMs: positionMs,
                )
            } else {
                // No tracks in queue, just transfer playback
                try await SpotifyAPI.transferPlayback(accessToken: accessToken, deviceId: device.id, play: true)
            }

            // Activate Spotify Connect mode in PlaybackViewModel
            // This pauses local playback and routes controls to Web API
            PlaybackViewModel.shared.activateSpotifyConnect(deviceId: device.id, deviceName: device.name, accessToken: accessToken)

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
