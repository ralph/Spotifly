//
//  PlayerModel.swift
//  Spotifly
//
//  What the UI shows of the player.
//

import Foundation
import Observation

/// What the UI shows of the player, on the main actor.
///
/// The client yields a snapshot on every change and never waits for this side
/// to take it; one task applies them here. Nothing that reads the model needs a
/// subscription or a hop to the main queue, and a main thread that stalls finds
/// the newest state afterwards instead of working through every state in
/// between. Observation tracks what each view reads.
@MainActor
@Observable
final class PlayerModel {
    static let shared = PlayerModel(snapshots: LibrespotClient.shared.snapshots)

    /// The streaming session, as the connection dashboard shows it.
    private(set) var connection: SpotifyConnection?

    /// Whichever device is playing: this one, or another one, mirrored.
    private(set) var playback: PlaybackState?

    /// The queue around the current track, and the context it plays from.
    private(set) var queue: QueueState?

    /// The tracks playback found Spotify withholds this login, which no list had said.
    private(set) var withheld: Set<String> = []

    /// The logical Connect volume, 0–1; nil until one has been set.
    private(set) var volume: Double?

    /// The latest skip, or stop over an error, that the client published.
    private(set) var interruption: PlaybackInterruption?

    /// The active Connect device, or nil while none is. A transfer sets it ahead
    /// of the cluster; see `setActiveDevice(_:)`.
    private(set) var activeDeviceId: String?

    /// The cluster report last applied. A transfer compares it before and after,
    /// to tell whether one landed while it waited.
    private(set) var clusterRevision = 0

    /// The devices as the cluster reported them; nil until it has.
    private var reportedDevices: [Device]?

    /// Starts applying `snapshots`; without them, the model changes only
    /// through `apply(_:)`, which is what tests use.
    init(snapshots: AsyncStream<PlayerSnapshot>? = nil) {
        guard let snapshots else { return }
        Task { [weak self] in
            for await snapshot in snapshots {
                self?.apply(snapshot)
            }
        }
    }

    /// The Connect devices, each marked active by `activeDeviceId`.
    var devices: [Device] {
        (reportedDevices ?? []).map { $0.marked(active: $0.id == activeDeviceId) }
    }

    var activeDevice: Device? {
        devices.first { $0.isActive }
    }

    /// This Mac's Connect id.
    var ownDeviceId: String? {
        connection?.deviceId
    }

    /// Adopts a snapshot. Each part is written only when it changed, so what
    /// observes one part does not hear about another.
    func apply(_ snapshot: PlayerSnapshot) {
        let connection = snapshot.connection.map(SpotifyConnection.init)
        if connection != self.connection {
            self.connection = connection
        }
        if snapshot.playback != playback {
            playback = snapshot.playback
        }
        if snapshot.queue != queue {
            queue = snapshot.queue
        }
        if snapshot.withheld != withheld {
            withheld = snapshot.withheld
        }
        if snapshot.volume != volume {
            volume = snapshot.volume
        }
        if snapshot.interruption != interruption {
            interruption = snapshot.interruption
        }
        if snapshot.devices != reportedDevices {
            reportedDevices = snapshot.devices
        }
        // Every cluster report overrules a transfer's guess, including one that
        // names the device it named before: a transfer the target never took up
        // leaves the cluster where it was, and snapshots that arrive while the
        // main actor is busy are coalesced, so a report and its reversal can
        // come as one. A snapshot about something else leaves the guess alone.
        if snapshot.clusterRevision != clusterRevision {
            clusterRevision = snapshot.clusterRevision
            let reported = snapshot.activeDeviceId.isEmpty ? nil : snapshot.activeDeviceId
            if reported != activeDeviceId {
                activeDeviceId = reported
            }
        }
    }

    /// Marks a device active ahead of the cluster, so a transfer shows at once.
    /// The next cluster report replaces it.
    func setActiveDevice(_ deviceId: String?) {
        activeDeviceId = deviceId
    }
}

extension SpotifyConnection {
    init(_ state: LibrespotConnectionState) {
        self.init(
            deviceId: state.deviceId,
            deviceName: state.deviceName,
            isConnected: state.sessionConnected,
            connectedSince: state.connectedSinceMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            reconnectAttempts: state.reconnectAttempt,
            lastError: state.sessionConnected ? nil : state.lastError,
            streams: state.streams,
        )
    }
}

private extension Device {
    func marked(active: Bool) -> Device {
        guard active != isActive else { return self }
        return Device(
            id: id,
            name: name,
            type: type,
            isActive: active,
            isPrivateSession: isPrivateSession,
            isRestricted: isRestricted,
            volumePercent: volumePercent,
            disableVolume: disableVolume,
        )
    }
}
