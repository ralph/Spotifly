//
//  SpotifyPlayer.swift
//  Spotifly
//
//  The Spotify Connect facade the app speaks to.
//
//  A static namespace over `LibrespotClient.shared` for the session and the few
//  reads that must be synchronous. What the UI shows of the player it reads
//  from `PlayerModel`, which the client's snapshots feed. Playback commands go
//  over connect-state (`PlaybackViewModel`), to Soloist or another device.
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
    let isPaused: Bool
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
    let reconnectAttempt: UInt32
    let lastError: String?
    let connectedSinceMs: UInt64?
    /// Whether this Mac may play for the account: false for an account Spotify named other
    /// than Premium at login, or refused for want of it. See `LibrespotSession.streams`.
    let streams: Bool
}

/// Everything the player tells the app, as of one moment.
///
/// The client yields one on every change, to the one consumer that shows them:
/// `PlayerModel`. The facade's synchronous reads use the latest one.
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
    // MARK: - Lifecycle

    /// Initializes the session that controls playback: the dealer socket and the Spirc
    /// registration of a hidden device that does not play. Spotify's Soloist plays for this
    /// Mac (`SoloistEngine`).
    ///
    /// Every connect goes through here, from `PlaybackViewModel`'s lifecycle, and the client is
    /// told where its credentials come from: the stored reusable login from an earlier grant if
    /// there is one, else a fresh keymaster token, with the client token spclient requires.
    @SpotifyPlayerActor
    static func initialize() async throws {
        try await LibrespotClient.shared.initialize(
            httpCredentials: .live,
            usernameProvider: { await KeymasterSession.shared.username },
        )
    }

    /// Shuts down, which takes this device off Spotify Connect. Call this when the app is
    /// quitting.
    ///
    /// Awaitable so callers can order it against a rebuild of the same global player, and
    /// so the quit can wait for it.
    static func shutdown() async {
        await LibrespotClient.shared.shutdown()
    }

    /// Leaves Spotify Connect, then releases everything and clears every
    /// replaying publisher.
    ///
    /// The replay subjects are right within a session and wrong across a
    /// logout: the next account's services must not be handed the previous
    /// account's devices, queue or playback state. Subscribers treat nil as
    /// "nothing to say".
    nonisolated static func shutdownAndCleanup() async {
        await LibrespotClient.shared.shutdownAndCleanup()
    }

    /// Disconnects without preventing future reconnection.
    /// Use this before system sleep - the device disappears from Spotify immediately,
    /// but forceReconnect() can still bring it back on wake.
    static func disconnect() {
        Task { await LibrespotClient.shared.disconnect() }
    }

    /// Asks the client to reconnect, without tearing down what it already has.
    ///
    /// Preferred over `PlaybackViewModel.forceReinitialize` wherever a session may exist:
    /// reinitialize runs a destructive cleanup first, which invalidates any reconnect loop
    /// currently working the problem.
    @discardableResult
    static func forceReconnect() -> LibrespotClient.ForceReconnectOutcome {
        LibrespotClient.shared.forceReconnectSync()
    }

    // MARK: - Synchronous State

    /// Whether the session is currently connected and ready for playback commands.
    static var isSessionConnected: Bool {
        LibrespotClient.shared.currentConnectionState?.sessionConnected == true
    }

    // MARK: - Streaming Credentials

    /// Removes the cached streaming credentials so the next launch cannot connect the
    /// account that just logged out.
    ///
    /// Clears both halves of the grant. The reusable AP credentials live in the keychain
    /// beside the keymaster tokens; forgetting only the first would leave a long-lived refresh
    /// token for the signed-out account behind.
    static func clearStreamingCredentials() async {
        await LibrespotClient.shared.clearStreamingCredentials()
        await KeymasterSession.shared.clear()
    }

    // MARK: - Transfer

    /// Hands playback to a Connect device, Soloist included, from whichever device holds it.
    ///
    /// Goes over connect-state, beside every other Connect command this app sends. It used to
    /// go to `PUT /me/player` on `api.spotify.com` with the keymaster token, which cannot work:
    /// that grant uses the desktop client id, and Spotify answers it with 429 on every Web API
    /// endpoint.
    /// - Parameter deviceId: The target device ID to transfer playback to
    /// - Returns: `true` if the transfer was accepted.
    static func transferPlayback(to deviceId: String) async -> Bool {
        // The session's own device, which the backend does not check; it derives the source
        // from the session.
        guard let from = LibrespotClient.shared.currentConnectionState?.deviceId, !from.isEmpty, !deviceId.isEmpty else {
            debugLog("SpotifyPlayer", "Transfer skipped: no local device id yet")
            return false
        }

        do {
            try await SpclientAPI().transferPlayback(from: from, to: deviceId)
            return true
        } catch {
            debugLog("SpotifyPlayer", "Transfer to \(deviceId) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The tracks queueing `uri` means: the track, or an album's or playlist's tracks.
    static func queueableTracks(for uri: String) async throws -> [String] {
        try await LibrespotClient.shared.queueableTracks(for: uri)
    }
}

@globalActor
actor SpotifyPlayerActor {
    static let shared = SpotifyPlayerActor()
}
