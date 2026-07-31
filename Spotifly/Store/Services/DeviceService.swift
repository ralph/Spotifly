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
    private var loadDevicesTask: Task<Void, Never>?

    /// Timestamp of the last outgoing transfer, used to delay the
    /// `fetchInitialPlaybackState` that fires on reconnect (Web API is stale).
    private var lastTransferTime: ContinuousClock.Instant?

    /// Counts authoritative active-device updates from the cluster, so a transfer can tell
    /// whether one landed while it was awaiting Rust.
    private var activeDeviceUpdates = 0

    /// The transfer currently in flight, if any. Transfers are chained onto it so no two
    /// ever overlap — see `transferPlayback(to:accessToken:)`.
    private var transferTask: Task<Bool, Never>?

    /// Subject for event-driven load requests. Throttled so that bursts of triggers
    /// (e.g. sessionConnected firing right after the post-transfer delay) collapse
    /// into a single HTTP request.
    @ObservationIgnored private let loadSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored private var loadCancellable: AnyCancellable?
    @ObservationIgnored private var activeDeviceCancellable: AnyCancellable?

    init(store: AppStore) {
        self.store = store
        loadCancellable = loadSubject
            .throttle(for: .seconds(10), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] token in
                Task { await self?.loadDevices(accessToken: token) }
            }
        activeDeviceCancellable = SpotifyPlayer.activeDeviceChanged
            .sink { [weak self] deviceId in
                self?.activeDeviceUpdates += 1
                self?.store.setActiveDevice(deviceId)
            }
    }

    // MARK: - Device Loading

    /// Schedules an event-driven device list refresh, throttled to at most once per 10 seconds.
    /// Use for automatic triggers (sessionConnected, post-transfer confirmation).
    func scheduleLoad(accessToken: String) {
        loadSubject.send(accessToken)
    }

    /// Loads available Spotify Connect devices immediately (no throttle).
    /// Use for user-initiated refreshes (SpeakersView opening, pull-to-refresh).
    func loadDevices(accessToken: String) async {
        // If already loading, await existing task instead of starting a new one.
        // This handles view recreation where .task fires again before loading finishes.
        if let existingTask = loadDevicesTask {
            await existingTask.value
            return
        }

        store.devicesIsLoading = true
        store.devicesErrorMessage = nil

        loadDevicesTask = Task {
            defer {
                self.loadDevicesTask = nil
                self.store.devicesIsLoading = false
            }

            do {
                let response = try await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
                self.store.upsertDevices(response.devices)
            } catch is CancellationError {
                // Task was cancelled (e.g., view dismissed) - don't show error
            } catch let error as SpotifyAPIError {
                self.store.devicesErrorMessage = error.localizedDescription
            } catch {
                self.store.devicesErrorMessage = String(localized: "speakers.error.failed_to_load")
            }
        }

        await loadDevicesTask?.value
    }

    // MARK: - Playback Transfer

    /// Transfer playback to a specific device.
    /// Uses native Spotify Connect protocol for seamless handoff.
    /// Returns true if transfer succeeded (caller should activate Connect mode)
    ///
    /// Every speaker row launches its own task, so two taps can call this concurrently.
    /// Each attempt optimistically marks its target active and undoes that if Rust rejects
    /// the transfer, which is only sound while no other attempt is in flight: overlapping
    /// ones capture each other's optimistic values as the state to restore. Chaining onto
    /// the previous transfer keeps that from arising at all, and the later tap — the user's
    /// actual intent — still wins, because it runs last.
    func transferPlayback(to device: Device, accessToken: String) async -> Bool {
        let previous = transferTask
        let task = Task { @MainActor in
            _ = await previous?.value
            return await performTransfer(to: device, accessToken: accessToken)
        }
        transferTask = task
        defer {
            if transferTask == task {
                transferTask = nil
            }
        }
        return await task.value
    }

    private func performTransfer(to device: Device, accessToken: String) async -> Bool {
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

        // Rust can reject the transfer (no session, invalid session, SpClient failure).
        // Roll the optimistic update back rather than leaving the UI showing a device
        // that never became active, and report the failure to the caller.
        guard accepted else {
            debugLog("DeviceService", "Transfer to \(device.name) was rejected by Rust")
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

        // Schedule a throttled refresh after the transfer settles.
        // Using scheduleLoad means the sessionConnected-triggered load that fires
        // ~250ms later collapses into this one via the 10s throttle window.
        Task {
            try? await Task.sleep(for: .milliseconds(750))
            scheduleLoad(accessToken: accessToken)
        }

        return true
    }

    /// Waits if a transfer happened recently, giving the Web API time to reflect the new state.
    /// Call before `fetchInitialPlaybackState` on reconnect.
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
