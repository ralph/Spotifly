//
//  SpotifyPlayer.swift
//  Spotifly
//
//  The playback facade the app speaks to.
//
//  A static namespace over `LibrespotClient.shared` for commands and the few
//  reads that must be synchronous. What the UI shows of the player it reads
//  from `PlayerModel`, which the client's snapshots feed.
//

import Foundation

/// Queue item metadata. Field names aligned with Track for consistency.
nonisolated struct QueueItem: Identifiable, Equatable, Encodable {
    let id: String // uri
    let uri: String
    let name: String // Aligned with Track.name
    let artistName: String
    let imageURLString: String // Aligned with Track
    let durationMs: UInt32
    let albumId: String?
    let artistId: String?
    let externalUrl: String?
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    let provider: String

    var durationFormatted: String {
        formatTrackTime(milliseconds: Int(durationMs))
    }

    var imageURL: URL? {
        URL(string: imageURLString)
    }
}

/// Outcome of the one-time streaming authorization.
nonisolated enum StreamingAuthResult: Equatable {
    case authorized
    case failed
    /// A logout landed while the grant was in flight, and the credentials it wrote were
    /// removed again. Nothing went wrong, so this is reported as neither success nor error.
    case superseded
    /// The user abandoned the flow — closed the browser tab, or pressed Cancel. Distinct from
    /// `failed` because there is nothing to report: they asked for this.
    case cancelled
}

/// The queue around the current track, and the context it plays from.
nonisolated struct QueueState: Equatable {
    /// Empty when playback started from a bare list of tracks.
    let contextUri: String
    let currentTrack: QueueItem?
    let nextTracks: [QueueItem]
    let previousTracks: [QueueItem]
}

/// Playback state as reported by the local player or a remote command.
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
}

/// Playback that went past a track, or stopped, over an error.
///
/// Auto-advance, a remote command and a pipeline error are started by the client, not by a
/// call from the app, so their errors have no caller to be thrown to. They reach the
/// now-playing bar this way. A play the app started comes this way too, and throws the same
/// text, which `PlaybackViewModel.errorMessage` takes once.
nonisolated struct PlaybackInterruption: Equatable {
    /// What the now-playing bar says. A message about a track puts the reason before the
    /// track's name, because the bar cuts off what does not fit, and the name can go.
    let message: String
    /// Tells one interruption from the next, counted on the snapshot as `clusterRevision` is.
    /// The model passes on changes only, so without it the same track skipped twice in a row
    /// would be told once.
    let sequence: Int
}

/// Connection state of the streaming session.
nonisolated struct LibrespotConnectionState: Equatable {
    let sessionConnected: Bool
    let deviceId: String?
    let deviceName: String
    let reconnectAttempt: UInt32
    let lastError: String?
    let connectedSinceMs: UInt64?
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
    /// Whichever device is playing: this one, or another one, mirrored.
    var playback: PlaybackState?
    var queue: QueueState?
    /// The logical Connect volume, 0–1; nil until one has been set.
    var volume: Double?
    /// The latest interruption. It stays until the next one, so a consumer that falls behind
    /// and gets a later snapshot still sees it.
    var interruption: PlaybackInterruption?
}

/// The one audio output. Fed by the decode loop inside the pipeline; volume,
/// routing recovery and pacing all live in it.
private nonisolated let audioRendererInstance = AudioRenderer()

enum SpotifyPlayer {
    /// The shared audio sink the client's pipeline renders into.
    nonisolated static var audioRenderer: AudioRenderer {
        audioRendererInstance
    }

    // MARK: - Lifecycle

    /// Initializes the player: accesspoint login, dealer socket, Spirc
    /// registration, audio pipeline.
    ///
    /// Credentials resolve inside the client — the stored reusable login from
    /// an earlier grant if there is one, else a fresh keymaster token.
    @SpotifyPlayerActor
    static func initialize() async throws {
        syncSettingsFromUserDefaults()
        try await connectClient()
    }

    /// The one place the client is told where its credentials come from.
    ///
    /// Written once because the post-grant connect used to spell it out for
    /// itself and left the client token out, which is not optional: spclient
    /// signs like the desktop client, so that session could fetch no metadata,
    /// no CDN url and no context at all. It survived only because the grant
    /// path immediately rebuilds through `initialize`.
    private static func connectClient() async throws {
        try await LibrespotClient.shared.initialize(
            tokenProvider: { try await KeymasterSession.shared.accessToken() },
            clientTokenProvider: { try await ClientTokenProvider.shared.token() },
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

    /// Tells playback which tracks Spotify will not play, from what the app's lists said, so
    /// that it steps over them instead of loading each to find out.
    static func setUnplayable(_ uris: Set<String>) {
        Task { await LibrespotClient.shared.setUnplayable(uris) }
    }

    // MARK: - Synchronous State

    /// Whether the session is currently connected and ready for playback commands.
    static var isSessionConnected: Bool {
        LibrespotClient.shared.currentConnectionState?.sessionConnected == true
    }

    /// Whether this device is the active Spotify Connect device. When it is not,
    /// transport controls go to the one that is, over connect-state.
    static var isActiveDevice: Bool {
        LibrespotClient.shared.isActiveDeviceFlagValue
    }

    /// Whether the player is currently playing.
    static var isPlaying: Bool {
        LibrespotClient.shared.isPlayingFlagValue
    }

    /// The current playback position in milliseconds.
    /// This is the actual audible position, not an estimate.
    static var positionMs: UInt32 {
        UInt32(min(UInt64(UInt32.max), LibrespotClient.shared.positionMsCached))
    }

    // MARK: - Playback Commands

    /// Plays content by its Spotify URI or URL.
    /// Supports tracks, albums, playlists, artists, and station contexts.
    /// - Parameters:
    ///   - uriOrUrl: Spotify URI or URL (e.g., "spotify:album:xxx")
    ///   - trackIndex: Track index to start at (-1 = from beginning, 0+ = specific track)
    @SpotifyPlayerActor
    static func play(uriOrUrl: String, trackIndex: Int = -1) async throws {
        try await LibrespotClient.shared.play(uriOrUrl: uriOrUrl, trackIndex: trackIndex)
    }

    /// Plays a track by its Spotify track ID.
    @SpotifyPlayerActor
    static func playTrack(trackId: String) async throws {
        try await play(uriOrUrl: "spotify:track:\(trackId)")
    }

    /// Plays multiple tracks in sequence.
    /// - Parameter trackUris: Array of Spotify track URIs
    @SpotifyPlayerActor
    static func playTracks(_ trackUris: [String]) async throws {
        try await LibrespotClient.shared.playTracks(trackUris)
    }

    /// Pauses playback.
    static func pause() {
        Task { await LibrespotClient.shared.pause() }
    }

    /// Resumes playback, or takes over another device's track the bar mirrors.
    static func resume() async throws {
        try await LibrespotClient.shared.resume()
    }

    /// Stops playback.
    static func stop() {
        Task { await LibrespotClient.shared.stop() }
    }

    /// Skips to the next track in the queue.
    static func next() async throws {
        try await LibrespotClient.shared.next()
    }

    /// Skips to the previous track in the queue.
    static func previous() async throws {
        try await LibrespotClient.shared.previous()
    }

    /// Seeks to the given position in milliseconds.
    static func seek(positionMs: UInt32) async throws {
        try await LibrespotClient.shared.seek(positionMs: positionMs)
    }

    /// Sets the playback volume (0.0 - 1.0).
    /// Reports the logical Connect volume; see `setOutputVolume` for the gain path.
    static func setVolume(_ volume: Double) {
        Task { await LibrespotClient.shared.setVolume(volume) }
    }

    /// Applies playback volume at the audio output for an immediate,
    /// buffer-independent response. The slider value is passed through a
    /// logarithmic taper so the perceived loudness curve matches librespot's.
    nonisolated static func setOutputVolume(_ volume: Double) {
        audioRenderer.setVolume(Float(librespotLogAttenuation(volume)))
    }

    /// Mirrors librespot's default `VolumeCtrl::Log(60 dB)` mapping
    /// (`playback/src/mixer/mappings.rs`): `attenuation = exp(ln(r) * v) / r`,
    /// where `r = db_to_ratio(60) = 10^(60/20) = 1000`. Zero and full are
    /// special-cased to true mute / unity, matching librespot.
    private nonisolated static func librespotLogAttenuation(_ volume: Double) -> Double {
        let v = max(0, min(1, volume))
        if v <= 0 {
            return 0
        }
        if v >= 1 {
            return 1
        }
        let dbRatio = 1000.0
        return exp(log(dbRatio) * v) / dbRatio
    }

    /// Enables or disables shuffle on the local player.
    static func setShuffle(_ enabled: Bool) {
        Task { await LibrespotClient.shared.setShuffle(enabled) }
    }

    /// Plays radio for a seed track.
    /// - Parameter trackUri: The Spotify track URI to use as seed
    static func playRadio(trackUri: String) async throws {
        try await LibrespotClient.shared.playRadio(trackUri: trackUri)
    }

    // MARK: - Streaming Authorization

    /// Runs the one-time streaming authorization.
    ///
    /// Swift mints the token now — see `KeymasterAuth` — and hands it to the
    /// client, which logs the AP in once and stores the reusable credentials
    /// every later init connects from. The token is adopted into
    /// `KeymasterSession` before the connect rather than after, so it survives
    /// even if the connect fails.
    ///
    /// Blocks on a human, so it runs off the main actor, and it is cancellable for the same
    /// reason: the browser wait unwinds on cancellation, and so does the token exchange behind
    /// it. The connect that follows does not — it is detached, so that a grant already written
    /// to the keychain finishes registering this Mac rather than being abandoned half done.
    static func authorizeStreaming() async -> StreamingAuthResult {
        let tokens: KeymasterTokens
        do {
            tokens = try await KeymasterAuth.authorize()
            try await KeymasterSession.shared.adopt(tokens)
        } catch is CancellationError {
            debugLog("SpotifyPlayer", "Streaming authorization cancelled")
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            // The same cancellation, reported differently. Only the browser wait answers with
            // `CancellationError`; once the redirect has landed the flow is inside
            // `URLSession`, which reports a cancelled task as a `URLError` of its own — and
            // falling through to `.failed` there told the user their connection had failed
            // when what happened is that they pressed Cancel.
            debugLog("SpotifyPlayer", "Streaming authorization cancelled during token exchange")
            return .cancelled
        } catch {
            debugLog("SpotifyPlayer", "Streaming authorization failed: \(error)")
            return .failed
        }

        // The connect runs detached: `.utility`, because a user-initiated caller parked on a
        // lower-QoS worker is a priority inversion, and non-cancellable, because a grant
        // already persisted should finish registering this Mac.
        return await Task.detached(priority: .utility) {
            do {
                try await connectClient()
                return .authorized
            } catch is CancellationError {
                return .superseded
            } catch {
                debugLog("SpotifyPlayer", "Post-grant connect failed: \(error)")
                return .failed
            }
        }.value
    }

    /// The Spotify account id the last successful grant authenticated as.
    ///
    /// The browser runs the grant with whatever account it is signed into, which need not be
    /// the one already signed in here. Read straight from the keychain so the answer stays
    /// synchronous and does not depend on a live session object.
    static func lastGrantAccountId() -> String? {
        KeymasterKeychainStore().load()?.username
    }

    /// Removes the cached streaming credentials so the next launch cannot connect the
    /// account that just logged out.
    ///
    /// Clears both halves of the grant. The reusable AP credentials live in the app
    /// container; the keymaster tokens are a keychain item Swift owns. Forgetting only the
    /// first would leave a long-lived refresh token for the signed-out account behind.
    static func clearStreamingCredentials() async {
        await LibrespotClient.shared.clearStreamingCredentials()
        await KeymasterSession.shared.clear()
    }

    // MARK: - Transfer

    /// Takes over playback that is running on another Connect device.
    /// - Returns: `true` if the transfer was accepted.
    static func transferToLocal() async -> Bool {
        // Naming this device on both sides is how librespot pulls playback to
        // itself; the backend derives the source from the session anyway.
        await transfer(to: localDeviceId())
    }

    /// Hands playback from this device to another one.
    /// - Parameter deviceId: The target device ID to transfer playback to
    /// - Returns: `true` if the transfer was accepted.
    static func transferPlayback(to deviceId: String) async -> Bool {
        await transfer(to: deviceId)
    }

    /// This device's Connect id, as the cluster knows it.
    private static func localDeviceId() -> String? {
        LibrespotClient.shared.currentConnectionState?.deviceId.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Both transfers go over connect-state, beside every other Connect command
    /// this app sends. They used to go to `PUT /me/player` on `api.spotify.com`
    /// with the keymaster token, which cannot work: that grant uses the desktop
    /// client id, and Spotify answers it with 429 on every Web API endpoint.
    private static func transfer(to deviceId: String?) async -> Bool {
        guard let from = localDeviceId(), let deviceId, !deviceId.isEmpty else {
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

    /// Adds an item to the queue.
    /// - Parameter uri: The Spotify URI to add to the queue (track, episode, etc.)
    static func addToQueue(uri: String) {
        Task { await LibrespotClient.shared.addToQueue(uri: uri) }
    }

    /// The tracks queueing `uri` means: the track, or an album's or playlist's tracks.
    static func queueableTracks(for uri: String) async throws -> [String] {
        try await LibrespotClient.shared.queueableTracks(for: uri)
    }

    // MARK: - Playback Settings

    /// Streaming bitrate options
    enum Bitrate: UInt8, CaseIterable, Identifiable {
        case low = 0 // 96 kbps
        case normal = 1 // 160 kbps (default)
        case high = 2 // 320 kbps

        var id: UInt8 {
            rawValue
        }

        var displayName: String {
            switch self {
            case .low: "Low (96 kbps)"
            case .normal: "Normal (160 kbps)"
            case .high: "High (320 kbps)"
            }
        }

        var isDefault: Bool {
            self == .normal
        }
    }

    /// Sets the streaming bitrate. Takes effect on the next track load.
    static func setBitrate(_ bitrate: Bitrate) {
        UserDefaults.standard.set(bitrate.rawValue, forKey: "streamingBitrate")
        Task { await LibrespotClient.shared.applyPlaybackSettings() }
    }

    /// The stored bitrate setting, defaulting to normal. `nonisolated` so the
    /// client can read it while applying the setting to a new pipeline.
    nonisolated static var bitrate: Bitrate {
        Bitrate(rawValue: UInt8(UserDefaults.standard.object(forKey: "streamingBitrate") as? Int ?? 1)) ?? .normal
    }

    /// Sets gapless playback: the next track decoded into the sink behind the
    /// current one. Takes effect at the next track change.
    static func setGapless(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "gaplessPlayback")
        Task { await LibrespotClient.shared.applyPlaybackSettings() }
    }

    /// The stored gapless setting, defaulting to on. `nonisolated` like
    /// `bitrate`: applying it to a new pipeline must not wait for the main thread.
    nonisolated static var gapless: Bool {
        UserDefaults.standard.object(forKey: "gaplessPlayback") as? Bool ?? true
    }

    private nonisolated static func syncSettingsFromUserDefaults() {
        let savedVolume = UserDefaults.standard.double(forKey: "playbackVolume")
        // Apply the saved volume at the output up front so the first moments
        // of audio do not play at full volume.
        setOutputVolume(savedVolume > 0 ? savedVolume : 0.5)
    }
}

@globalActor
actor SpotifyPlayerActor {
    static let shared = SpotifyPlayerActor()
}
