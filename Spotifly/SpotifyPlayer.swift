//
//  SpotifyPlayer.swift
//  Spotifly
//
//  What the Connect session publishes, and the two calls that bind it to the account.
//
//  The snapshot types the client yields, and `SpotifyPlayer`, which starts the session with
//  the keymaster grant and forgets it at logout. Everything else goes to
//  `LibrespotClient.shared` directly. What the UI shows of the player it reads from
//  `PlayerModel`, which the client's snapshots feed. Playback commands go over connect-state
//  (`PlaybackViewModel`), to Soloist or another device.
//

import Foundation

/// A row of the player's queue: its track, where it comes from, and its uid. Names, artwork and
/// durations come from the store, which hydrates them by track id.
nonisolated struct QueueItem: Equatable {
    let uri: String
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    let provider: String
    /// The row's uid, as the cluster names it, which a jump to it names. A row with none goes
    /// by its position and its track.
    var uid: String?
}

/// The queue around the current track, and the context it plays from.
nonisolated struct QueueState: Equatable {
    /// Empty when playback started from a bare list of tracks.
    let contextUri: String
    let currentTrack: QueueItem?
    let nextTracks: [QueueItem]
    /// What played before the current track, in play order: the most recent last.
    let previousTracks: [QueueItem]
    /// The context's own name, as the cluster gives it.
    var contextName: String?

    /// The context the queue plays from, or nil for a bare list of tracks.
    var context: String? {
        contextUri.isEmpty ? nil : contextUri
    }
}

/// Playback state as the cluster reports it, for whichever device plays.
nonisolated struct PlaybackState: Equatable {
    let isPlaying: Bool
    let trackUri: String
    let positionMs: Int64
    let durationMs: Int64
    let shuffle: Bool
    let repeatTrack: Bool
    let repeatContext: Bool
    /// Timestamp (ms since epoch) when positionMs was recorded - for computing current position
    let timestampMs: Int64
    /// Whether Next goes anywhere: unless the device's `restrictions` say no.
    var canSkipNext = true
    /// Whether shuffle may be switched on: not on a station, whose context does not allow it.
    var canShuffle = true
    /// Whether repeat may be switched on from off, which a station does not allow either.
    var canRepeat = true
}

/// Connection state of the streaming session.
nonisolated struct LibrespotConnectionState: Equatable {
    let sessionConnected: Bool
    let deviceId: String?
    let deviceName: String
    let lastError: String?
    let connectedSinceMs: UInt64?
}

/// Everything the player tells the app, as of one moment.
///
/// The client yields one on every change, to the one consumer that shows them:
/// `PlayerModel`. The client's synchronous reads use the latest one.
nonisolated struct PlayerSnapshot: Equatable {
    var connection: LibrespotConnectionState?
    /// The Connect devices; nil until the first cluster has arrived.
    var devices: [Device]?
    /// Empty while no device is active.
    var activeDeviceId = ""
    /// Counts the cluster reports, so the model can let a fresh one overrule a
    /// transfer's guess even when it names the device it named before.
    var clusterRevision = 0
    /// Whichever device is playing, mirrored from the cluster.
    var playback: PlaybackState?
    var queue: QueueState?
}

enum SpotifyPlayer {
    /// Initializes the session that controls playback: the dealer socket and the Spirc
    /// registration of a hidden device that does not play. Spotify's Soloist plays for this
    /// Mac (`SoloistEngine`).
    ///
    /// Every connect goes through here, from `PlaybackViewModel`'s lifecycle, and the client is
    /// told where its credentials come from: the keymaster grant, with the client token
    /// spclient requires.
    static func initialize() async throws {
        try await LibrespotClient.shared.initialize(httpCredentials: .live)
    }

    /// Removes the credentials so neither a recovery nor the next launch can connect the
    /// account that just logged out: the session's, and the keymaster tokens in the keychain,
    /// a long-lived refresh token for the signed-out account if left behind.
    static func clearStreamingCredentials() async {
        await LibrespotClient.shared.clearStreamingCredentials()
        await KeymasterSession.shared.clear()
    }
}
