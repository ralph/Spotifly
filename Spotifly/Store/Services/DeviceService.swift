//
//  DeviceService.swift
//  Spotifly
//
//  Service for Spotify Connect device operations.
//  Handles API calls and updates AppStore on success.
//

import Combine
import Foundation

@MainActor
@Observable
final class DeviceService {
    private let store: AppStore

    /// Timestamp of the last outgoing transfer, used to delay the
    /// `fetchInitialPlaybackState` that fires on reconnect.
    private var lastTransferTime: ContinuousClock.Instant?

    /// Counts authoritative active-device updates from the cluster, so a transfer can tell
    /// whether one landed while it was awaiting the transfer request.
    private var activeDeviceUpdates = 0

    /// The transfer currently in flight, if any. Transfers are chained onto it so no two
    /// ever overlap — see `transferPlayback(to:)`.
    private var transferTask: Task<Bool, Never>?

    @ObservationIgnored private var devicesCancellable: AnyCancellable?
    @ObservationIgnored private var activeDeviceCancellable: AnyCancellable?

    init(store: AppStore) {
        self.store = store
    }

    /// Starts the throttled device load and active-device tracking. Call once, from the
    /// view that kept this instance.
    ///
    /// Deliberately not done in `init`: SwiftUI runs a View's `init` repeatedly and keeps
    /// only the first `State(initialValue:)`, so a discarded instance would keep issuing
    /// device requests and writing active-device changes into a store nothing reads.
    ///
    /// Idempotent — the guard reads the subscription it protects.
    func activate() {
        guard devicesCancellable == nil else { return }
        recordActivation(self)
        // Both of these are fed from inside the LibrespotClient actor, and a
        // Combine subject delivers to its subscribers *synchronously* on
        // whatever thread sent. These closures touch the main-actor store, so
        // without the hop the isolation check traps — which is exactly what
        // happened the first time a real cluster arrived.
        devicesCancellable = SpotifyPlayer.devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self, let devices else { return }
                store.upsertDevices(devices)
                store.devicesIsLoading = false
            }
        activeDeviceCancellable = SpotifyPlayer.activeDeviceChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceId in
                self?.activeDeviceUpdates += 1
                self?.store.setActiveDevice(deviceId)
            }
    }

    // MARK: - Device Loading

    // **Devices are not loaded any more; they arrive.**
    //
    // `/me/player/devices` was an HTTP poll, which is why this service used to carry a
    // throttled subject, an in-flight task and an error message. The cluster pushes the same
    // list over the dealer socket librespot already holds, so the whole apparatus is gone and
    // what is left is a subscription. A device appearing or disappearing now reaches Speakers
    // without anyone asking.
    //
    // **A push alone is not enough to start with**, which was measured the hard way: the
    // dealer only carries *changes*, and the device's own registration is answered over HTTP
    // rather than pushed — so on a quiet account nothing arrived at all and Speakers stayed
    // empty while a Connect stereo sat there reachable. `SpircController.registerDevice`
    // adopts the cluster that answers its PutState as well as subscribing to the pushes, and
    // both arrive here by the same route.
    //
    // `devicesIsLoading` stays true until the first list lands, and the publisher replays it
    // to a Speakers view opened later.

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
        let previousActiveDeviceId = store.activeDeviceId
        let updatesBeforeTransfer = activeDeviceUpdates
        store.setActiveDevice(device.id)

        // Check if target is our local device
        let isLocalDevice = device.id == store.connection?.deviceId

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
            // which the store alone cannot distinguish from the optimistic update.
            //
            // An empty ID clears the flag on every device, which is the right rollback when
            // nothing was active before. Skipping the call in that case, as this used to,
            // left the target marked active even though the transfer was rejected.
            if activeDeviceUpdates == updatesBeforeTransfer {
                store.setActiveDevice(previousActiveDeviceId ?? "")
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
