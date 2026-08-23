//
//  SpotifyPlayer.swift
//  Spotifly
//
//  The playback facade the app speaks to.
//
//  A static namespace over `LibrespotClient.shared` — the pure-Swift
//  replacement for the Rust librespot bridge this file used to wrap. Every
//  type here is the same shape it was across the FFI, so services and views
//  needed no changes; only where the data comes from did.
//

import Combine
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

/// Queue state containing current, next, and previous tracks.
struct QueueState {
    let currentTrack: QueueItem?
    let nextTracks: [QueueItem]
    /// Previous tracks from the queue history
    let previousTracks: [QueueItem]?
}

/// Playback state as reported by the local player or a remote command.
struct PlaybackState: Equatable {
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

/// Loading notification containing track URI and position (fires early, before metadata is fetched)
struct LoadingNotification {
    let trackUri: String
    let positionMs: UInt32
}

/// Track info in a set queue notification
struct SetQueueTrackInfo {
    let uri: String
    let provider: String
}

/// Set queue notification containing the full queue state with context info
struct SetQueueNotification {
    let contextUri: String
    let currentTrack: SetQueueTrackInfo?
    let nextTracks: [SetQueueTrackInfo]
    let prevTracks: [SetQueueTrackInfo]
}

/// Connection state of the streaming session.
///
/// `revision` orders snapshots on arrival: several sources publish
/// independently (session events, cluster updates, recovery), and a delayed
/// older snapshot must not overwrite a newer one. See `deliverConnectionState`.
nonisolated struct LibrespotConnectionState: Equatable, Codable {
    let revision: UInt64
    let sessionConnected: Bool
    let sessionConnectionId: String?
    let spircReady: Bool
    let deviceId: String?
    let deviceName: String
    let reconnectAttempt: UInt32
    let lastError: String?
    let connectedSinceMs: UInt64?
    /// Whether Spotifly is the active Connect device — derived from the
    /// cluster's active device id. The single fact that playback routing and
    /// the UI both read.
    let isActiveDevice: Bool

    enum CodingKeys: String, CodingKey {
        case revision
        case sessionConnected = "session_connected"
        case sessionConnectionId = "session_connection_id"
        case spircReady = "spirc_ready"
        case deviceId = "device_id"
        case deviceName = "device_name"
        case reconnectAttempt = "reconnect_attempt"
        case lastError = "last_error"
        case connectedSinceMs = "connected_since_ms"
        case isActiveDevice = "is_active_device"
    }
}

// MARK: - Bridge Subjects

//
// The client's publishers are re-exposed here so subscribers keep reading the
// exact same static API as before the Rust removal.

private nonisolated(unsafe) let connectionStateSubjectBridge = LibrespotClient.shared.connectionState

/// The one audio output. Fed by the decode loop inside the pipeline; volume,
/// routing recovery and pacing all live in it.
private nonisolated let audioRendererInstance = AudioRenderer()

enum SpotifyPlayer {
    /// The shared audio sink the client's pipeline renders into.
    nonisolated static var audioRenderer: AudioRenderer {
        audioRendererInstance
    }

    // MARK: Publishers

    static var queue: AnyPublisher<QueueState?, Never> {
        LibrespotClient.shared.queue
    }

    static var playbackState: AnyPublisher<PlaybackState?, Never> {
        LibrespotClient.shared.playbackState
    }

    /// Remote volume changes (0-65535), including changes made from another device.
    static var volumeChanged: AnyPublisher<UInt16, Never> {
        LibrespotClient.shared.volumeChanged
    }

    /// Fires early when a track starts loading, before metadata is fetched.
    static var loading: AnyPublisher<LoadingNotification, Never> {
        LibrespotClient.shared.loading
    }

    /// Fires when the queue is set/modified (e.g., from a mobile app set_queue command).
    static var setQueue: AnyPublisher<SetQueueNotification, Never> {
        LibrespotClient.shared.setQueue
    }

    /// Emits when this device stops being the active Connect device.
    ///
    /// Activity, not health. Do not drive reconnection from this — use `connectionState`,
    /// which is the authoritative source for whether commands can be sent.
    static var becameInactive: AnyPublisher<Void, Never> {
        LibrespotClient.shared.becameInactive
    }

    /// Emits when this device becomes the active Connect device.
    ///
    /// Also activity, not readiness: the session was already connected beforehand.
    static var becameActive: AnyPublisher<Void, Never> {
        LibrespotClient.shared.becameActive
    }

    /// The Connect device list, pushed on cluster updates. Replaces `/me/player/devices`.
    static var devices: AnyPublisher<[Device]?, Never> {
        LibrespotClient.shared.devices
    }

    static var activeDeviceChanged: AnyPublisher<String, Never> {
        LibrespotClient.shared.activeDeviceChanged
    }

    /// Connection state updates. Subscribe to this to update the connection status dashboard.
    static var connectionState: AnyPublisher<LibrespotConnectionState?, Never> {
        LibrespotClient.shared.connectionState
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

    /// Shuts down and sends goodbye to other devices.
    /// Call this when the app is quitting to properly disconnect from Spotify Connect.
    ///
    /// Awaitable so callers can order it against a rebuild of the same global player.
    ///
    /// `nonisolated` matters at app termination: the project builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a main-actor-isolated version could
    /// not start until `applicationWillTerminate` returned — by which point AppKit may
    /// already have torn the process down.
    nonisolated static func shutdown() async {
        await LibrespotClient.shared.shutdown()
    }

    /// Says goodbye to other Connect devices, then releases everything and
    /// clears every replaying publisher.
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

    /// Outcome of a force-reconnect request.
    ///
    /// `alreadyRecovering` and `noSession` both mean "nothing was started", but they need
    /// opposite responses: the first is fine to ignore because recovery is already under
    /// way, while the second means there is nothing to reconnect *to* and only a full
    /// rebuild will help. Collapsing them into one `false` is how a wake could end up
    /// doing nothing at all.
    enum ForceReconnectOutcome {
        case started
        case alreadyRecovering
        case noSession
    }

    /// Asks the client to reconnect, without tearing down what it already has.
    ///
    /// Preferred over `PlaybackViewModel.forceReinitialize` wherever a session may exist:
    /// reinitialize runs a destructive cleanup first, which invalidates any reconnect loop
    /// currently working the problem.
    @discardableResult
    static func forceReconnect() -> ForceReconnectOutcome {
        switch LibrespotClient.shared.forceReconnectSync() {
        case .started: .started
        case .alreadyRecovering: .alreadyRecovering
        case .noSession: .noSession
        }
    }

    // MARK: - Synchronous State

    /// Whether the session is currently connected and ready for playback commands.
    static var isSessionConnected: Bool {
        LibrespotClient.shared.currentConnectionState?.sessionConnected == true
    }

    /// Whether Spirc is initialized and connected to Spotify Connect.
    static var isSpircReady: Bool {
        LibrespotClient.shared.currentConnectionState?.spircReady == true
    }

    /// Whether this device is the active Spotify Connect device.
    /// When false, playback controls should use Web API instead of Spirc.
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

    /// The current connection state synchronously, published like any push.
    static func getConnectionState() -> LibrespotConnectionState? {
        LibrespotClient.shared.currentConnectionState
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

    /// Resumes playback.
    static func resume() {
        Task { await LibrespotClient.shared.resume() }
    }

    /// Stops playback.
    static func stop() {
        Task { await LibrespotClient.shared.stop() }
    }

    /// Skips to the next track in the queue.
    static func next() {
        Task { try? await LibrespotClient.shared.next() }
    }

    /// Skips to the previous track in the queue.
    static func previous() {
        Task { try? await LibrespotClient.shared.previous() }
    }

    /// Seeks to the given position in milliseconds.
    static func seek(positionMs: UInt32) {
        Task { try? await LibrespotClient.shared.seek(positionMs: positionMs) }
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
    static func playRadio(trackUri: String) {
        Task { try? await LibrespotClient.shared.playRadio(trackUri: trackUri) }
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
        getConnectionState()?.deviceId.flatMap { $0.isEmpty ? nil : $0 }
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
        Task { await LibrespotClient.shared.applyStreamingQuality() }
    }

    /// The stored bitrate setting, defaulting to normal. `nonisolated` so the
    /// client can read it while applying the setting to a new pipeline.
    nonisolated static var bitrate: Bitrate {
        Bitrate(rawValue: UInt8(UserDefaults.standard.object(forKey: "streamingBitrate") as? Int ?? 1)) ?? .normal
    }

    /// Sets gapless playback. Reserved: auto-advance already keeps gaps small;
    /// sample-accurate cross-track scheduling is not implemented yet.
    static func setGapless(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "gaplessPlayback")
    }

    /// Gets the gapless playback setting.
    static var gapless: Bool {
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

/// The last queue state the client published, or nil if none has arrived.
///
/// The push equivalent of `/me/player/queue`, for the recovery paths that need to ask
/// rather than wait. Nil is meaningful and distinct from an empty queue: it means nothing
/// has been heard yet, so a caller should try again rather than conclude nothing is playing.
nonisolated func currentQueueSnapshot() -> QueueState? {
    LibrespotClient.shared.queueSnapshotValue
}
