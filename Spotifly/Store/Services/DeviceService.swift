//
//  DeviceService.swift
//  Spotifly
//
//  Service for Spotify Connect device operations.
//

import Foundation

/// Transfers playback between Connect devices.
///
/// **Devices are not loaded; they arrive.** The cluster pushes the device list over the
/// dealer socket, and `PlayerModel` holds it. A push alone is not enough to start with: the
/// dealer only carries *changes*, and this device's own registration is answered over HTTP
/// rather than pushed, so on a quiet account nothing arrived at all. `SpircController`
/// adopts the cluster that answers its PutState as well, and both reach the model the same
/// way.
@MainActor
@Observable
final class DeviceService {
    private let player: PlayerModel

    /// Timestamp of the last outgoing transfer, used to delay the
    /// `fetchInitialPlaybackState` that fires on reconnect.
    private var lastTransferTime: ContinuousClock.Instant?

    /// The transfer currently in flight, if any. Transfers are chained onto it so no two
    /// ever overlap — see `transferPlayback(to:)`.
    private var transferTask: Task<Bool, Never>?

    init(player: PlayerModel = .shared) {
        self.player = player
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device.
    /// Uses native Spotify Connect protocol for seamless handoff.
    /// Returns true if transfer succeeded (caller should activate Connect mode)
    ///
    /// Every speaker row launches its own task, so two taps can call this concurrently.
    /// Each attempt optimistically marks its target active and undoes that if the transfer
    /// is refused, which is only sound while no other attempt is in flight: overlapping
    /// ones capture each other's optimistic values as the state to restore. Chaining onto
    /// the previous transfer keeps that from arising at all, and the later tap — the user's
    /// actual intent — still wins, because it runs last.
    func transferPlayback(to device: Device) async -> Bool {
        let previous = transferTask
        let task = Task { @MainActor in
            _ = await previous?.value
            return await performTransfer(to: device)
        }
        transferTask = task
        defer {
            if transferTask == task {
                transferTask = nil
            }
        }
        return await task.value
    }

    private func performTransfer(to device: Device) async -> Bool {
        // Record transfer time so sessionConnected handler can delay its Web API fetch
        lastTransferTime = .now

        // Optimistically mark the target device as active for immediate UI feedback,
        // remembering the previous one so a rejected transfer can be undone
        let previousActiveDeviceId = player.activeDeviceId
        let updatesBeforeTransfer = player.activeDeviceUpdates
        player.setActiveDevice(device.id)

        // Check if target is our local device
        let isLocalDevice = device.id == player.ownDeviceId

        let accepted = if isLocalDevice {
            // Transfer TO local - use Spirc's native transfer
            await SpotifyPlayer.transferToLocal()
        } else {
            // Transfer FROM local to remote device
            await SpotifyPlayer.transferPlayback(to: device.id)
        }

        // The transfer can fail: no local device id yet, or connect-state refusing the
        // command. Roll the optimistic update back rather than leaving the UI showing a
        // device that never became active, and report the failure to the caller.
        guard accepted else {
            debugLog("DeviceService", "Transfer to \(device.name) was rejected")
            // Only undo the guess this call made. Serializing transfers rules out a
            // competing tap, but not the cluster: another client can activate a device
            // while this transfer is awaited, and that fact outranks restoring what was
            // true before the tap — including when it names the very device asked for,
            // which the active id alone cannot distinguish from the optimistic update.
            if player.activeDeviceUpdates == updatesBeforeTransfer {
                player.setActiveDevice(previousActiveDeviceId)
            }
            return false
        }

        // Nothing to schedule: the transfer changes the cluster, and the cluster pushes the
        // new device list and active device back on its own.
        return true
    }

    /// Waits if a transfer happened recently, giving the cluster time to push the state the
    /// transfer produced. Call before `fetchInitialPlaybackState` on reconnect, which reads
    /// the last cluster update and would otherwise read the one from before the transfer.
    func waitForTransferSettling() async {
        guard let transferTime = lastTransferTime else { return }
        let elapsed = transferTime.duration(to: .now)
        let staleWindow = Duration.seconds(5)
        if elapsed < staleWindow {
            try? await Task.sleep(for: staleWindow - elapsed)
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
