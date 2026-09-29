//
//  PlayerModelTests.swift
//  SpotiflyTests
//
//  How the player's snapshots become what the UI reads.
//

import Foundation
import Observation
@testable import Spotifly
import Synchronization
import Testing

@MainActor
struct PlayerModelTests {
    private func device(_ id: String, disableVolume: Bool = false) -> Device {
        Device(
            id: id,
            name: id,
            type: "computer",
            isActive: false,
            isPrivateSession: false,
            isRestricted: false,
            volumePercent: 50,
            disableVolume: disableVolume,
        )
    }

    private func cluster(active: String, revision: Int) -> PlayerSnapshot {
        PlayerSnapshot(
            devices: ["mac", "phone", "stereo"].map { device($0) },
            activeDeviceId: active,
            clusterRevision: revision,
        )
    }

    /// Whether what `read` reads would have been reported changed by `change`.
    private func notifies(reading read: () -> Void, on change: () -> Void) -> Bool {
        let notified = Mutex(false)
        withObservationTracking(read) { notified.withLock { $0 = true } }
        change()
        return notified.withLock { $0 }
    }

    /// A snapshot carries every part, and most snapshots change one. Rewriting the rest would
    /// wake everything that observes them, and hand the playback view model a position it has
    /// already anchored.
    @Test func `a snapshot writes only the parts that changed`() {
        let model = PlayerModel()
        var snapshot = cluster(active: "mac", revision: 1)
        snapshot.playback = PlaybackState(
            isPlaying: true, isPaused: false, trackUri: "spotify:track:a", positionMs: 1000,
            durationMs: 2000, shuffle: false, repeatTrack: false, repeatContext: false, timestampMs: 1,
        )
        model.apply(snapshot)

        snapshot.volume = 0.3
        let playbackNotified = notifies(reading: { _ = model.playback }) { model.apply(snapshot) }
        #expect(!playbackNotified)
        #expect(model.volume == 0.3)
    }

    @Test func `a transfer's guess stands until the next cluster report`() {
        let model = PlayerModel()
        model.apply(cluster(active: "phone", revision: 1))
        model.setActiveDevice("stereo")

        // A snapshot about something else carries the same report, and leaves the guess alone.
        var unrelated = cluster(active: "phone", revision: 1)
        unrelated.volume = 0.5
        model.apply(unrelated)
        #expect(model.activeDeviceId == "stereo")

        model.apply(cluster(active: "mac", revision: 2))
        #expect(model.activeDeviceId == "mac")
    }

    /// Found in review. The model followed the cluster only when it named a different device
    /// than before, so the guess stood, and the transport controls went to a device that was
    /// not playing.
    @Test func `a report naming the same device as before still overrules the guess`() {
        let model = PlayerModel()
        model.apply(cluster(active: "phone", revision: 1))
        model.setActiveDevice("stereo")

        // A transfer the stereo never took up, or phone → stereo → phone coalesced into one.
        model.apply(cluster(active: "phone", revision: 3))
        #expect(model.activeDeviceId == "phone")
    }

    /// `DeviceService` rolls a refused transfer back only if no report landed meanwhile.
    @Test func `every cluster report counts, and nothing else does`() {
        let model = PlayerModel()
        model.apply(cluster(active: "phone", revision: 1))

        var unrelated = cluster(active: "phone", revision: 1)
        unrelated.volume = 0.2
        model.apply(unrelated)
        #expect(model.clusterRevision == 1)

        model.apply(cluster(active: "", revision: 2))
        #expect(model.clusterRevision == 2)
        #expect(model.activeDeviceId == nil)
    }

    /// The store used to rebuild a device to flip its flag, and left `disableVolume` behind.
    @Test func `devices are marked by the active id and keep what they declared`() {
        let model = PlayerModel()
        model.apply(PlayerSnapshot(
            devices: [device("mac"), device("phone", disableVolume: true)],
            activeDeviceId: "mac",
            clusterRevision: 1,
        ))
        model.setActiveDevice("phone")

        #expect(model.devices.filter(\.isActive).map(\.id) == ["phone"])
        #expect(model.activeDevice?.disableVolume == true)
    }

    @Test func `a connected session shows no stale error`() {
        let model = PlayerModel()
        let connected = LibrespotConnectionState(
            sessionConnected: true, deviceId: "mac", deviceName: "Spotifly", reconnectAttempt: 0,
            lastError: "Connection lost", connectedSinceMs: 1_000_000, streams: true,
        )
        model.apply(PlayerSnapshot(connection: connected))

        #expect(model.connection?.lastError == nil)
        #expect(model.connection?.connectedSince == Date(timeIntervalSince1970: 1000))
        #expect(model.ownDeviceId == "mac")
    }
}
