//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the Rust librespot playback functionality
//

import Combine
import Foundation
import SpotiflyRust

/// Queue item metadata (nonisolated for C callback compatibility)
/// Field names aligned with Track for consistency
struct QueueItem: Sendable, Identifiable, Equatable, Encodable {
    nonisolated let id: String // uri
    nonisolated let uri: String
    nonisolated let name: String // Aligned with Track.name (was: trackName)
    nonisolated let artistName: String
    nonisolated let imageURLString: String // Aligned with Track (was: albumArtURL)
    nonisolated let durationMs: UInt32
    nonisolated let albumId: String?
    nonisolated let artistId: String?
    nonisolated let externalUrl: String?
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    nonisolated let provider: String

    nonisolated var durationFormatted: String {
        formatTrackTime(milliseconds: Int(durationMs))
    }

    /// Computed property for URL conversion
    var imageURL: URL? {
        URL(string: imageURLString)
    }

    /// Memberwise initializer
    nonisolated init(
        id: String,
        uri: String,
        name: String,
        artistName: String,
        imageURLString: String,
        durationMs: UInt32,
        albumId: String?,
        artistId: String?,
        externalUrl: String?,
        provider: String,
    ) {
        self.id = id
        self.uri = uri
        self.name = name
        self.artistName = artistName
        self.imageURLString = imageURLString
        self.durationMs = durationMs
        self.albumId = albumId
        self.artistId = artistId
        self.externalUrl = externalUrl
        self.provider = provider
    }
}

/// Queue state containing current, next, and previous tracks (nonisolated for C callback compatibility)
struct QueueState: Sendable {
    nonisolated let currentTrack: QueueItem?
    nonisolated let nextTracks: [QueueItem]
    /// Previous tracks from Mercury/Spirc
    nonisolated let previousTracks: [QueueItem]?
}

/// Playback state from Mercury/Spirc (nonisolated for C callback compatibility)
struct PlaybackState: Sendable, Equatable {
    nonisolated let isPlaying: Bool
    nonisolated let isPaused: Bool
    nonisolated let trackUri: String
    nonisolated let positionMs: Int64
    nonisolated let durationMs: Int64
    nonisolated let shuffle: Bool
    nonisolated let repeatTrack: Bool
    nonisolated let repeatContext: Bool
    /// Timestamp (ms since epoch) when positionMs was recorded - for computing current position
    nonisolated let timestampMs: Int64
}

/// Global subject for queue updates (nonisolated for C callback access)
private nonisolated(unsafe) let queueSubject = CurrentValueSubject<QueueState?, Never>(nil)

/// Global subject for playback state updates (nonisolated for C callback access)
private nonisolated(unsafe) let playbackStateSubject = CurrentValueSubject<PlaybackState?, Never>(nil)

/// Global subject for volume updates (nonisolated for C callback access)
private nonisolated(unsafe) let volumeSubject = PassthroughSubject<UInt16, Never>()

/// Loading notification containing track URI and position (fires early, before metadata is fetched)
struct LoadingNotification: Sendable {
    nonisolated let trackUri: String
    nonisolated let positionMs: UInt32
}

/// Global subject for loading notifications (nonisolated for C callback access)
private nonisolated(unsafe) let loadingSubject = PassthroughSubject<LoadingNotification, Never>()

/// Queue changed notification containing the track URI that was added
struct QueueChangedNotification: Sendable {
    nonisolated let trackUri: String
}

/// Track info in a set queue notification
struct SetQueueTrackInfo: Sendable {
    nonisolated let uri: String
    nonisolated let provider: String
}

/// Set queue notification containing the full queue state with context info
struct SetQueueNotification: Sendable {
    nonisolated let contextUri: String
    nonisolated let currentTrack: SetQueueTrackInfo?
    nonisolated let nextTracks: [SetQueueTrackInfo]
    nonisolated let prevTracks: [SetQueueTrackInfo]
}

/// Session client changed notification containing info about the controlling Spotify client
struct SessionClientChangedNotification: Sendable {
    nonisolated let clientId: String
    nonisolated let clientName: String
    nonisolated let clientBrandName: String
    nonisolated let clientModelName: String
}

/// Connection state from librespot (nonisolated for C callback compatibility)
struct LibrespotConnectionState: Sendable, Equatable, Encodable {
    nonisolated let sessionConnected: Bool
    nonisolated let sessionConnectionId: String?
    nonisolated let spircReady: Bool
    nonisolated let deviceId: String?
    nonisolated let deviceName: String
    nonisolated let reconnectAttempt: UInt32
    nonisolated let lastError: String?
    nonisolated let connectedSinceMs: UInt64?
}

/// Global subject for queue changed notifications (nonisolated for C callback access)
private nonisolated(unsafe) let queueChangedSubject = PassthroughSubject<QueueChangedNotification, Never>()

/// Global subject for set queue notifications (nonisolated for C callback access)
private nonisolated(unsafe) let setQueueSubject = PassthroughSubject<SetQueueNotification, Never>()

/// Global subject for connection state updates (nonisolated for C callback access)
private nonisolated(unsafe) let connectionStateSubject = CurrentValueSubject<LibrespotConnectionState?, Never>(nil)

/// Global subject for session client changed notifications (nonisolated for C callback access)
private nonisolated(unsafe) let sessionClientChangedSubject = PassthroughSubject<SessionClientChangedNotification, Never>()

/// Registers the queue callback with Rust (must be called from nonisolated context)
private nonisolated func registerQueueCallback() {
    spotifly_register_queue_callback { jsonPtr in
        handleQueueCallback(jsonPtr)
    }
}

/// Registers the playback state callback with Rust (must be called from nonisolated context)
private nonisolated func registerPlaybackStateCallback() {
    spotifly_register_playback_state_callback { jsonPtr in
        handlePlaybackStateCallback(jsonPtr)
    }
}

/// Registers the state update callback with Rust (fires on track changes)
private nonisolated func registerStateUpdateCallback() {
    spotifly_register_state_update_callback {
        handleStateUpdateCallback()
    }
}

/// Registers the volume callback with Rust (fires on remote volume changes)
private nonisolated func registerVolumeCallback() {
    spotifly_register_volume_callback { volume in
        handleVolumeCallback(volume)
    }
}

/// C callback for volume change notifications from Rust
private nonisolated func handleVolumeCallback(_ volume: UInt16) {
    debugLog("SpotifyPlayer", "Volume callback: \(volume)")
    volumeSubject.send(volume)
}

/// Registers the loading callback with Rust (fires when a track starts loading)
private nonisolated func registerLoadingCallback() {
    spotifly_register_loading_callback { jsonPtr in
        handleLoadingCallback(jsonPtr)
    }
}

/// C callback for loading notifications from Rust
/// Fires earlier than TrackChanged (~180ms vs ~620ms after remote command)
private nonisolated func handleLoadingCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleLoadingCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Loading callback: \(jsonString)")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let trackUri = json["track_uri"] as? String ?? ""
        let positionMs = (json["position_ms"] as? NSNumber)?.uint32Value ?? 0

        let notification = LoadingNotification(trackUri: trackUri, positionMs: positionMs)
        loadingSubject.send(notification)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse loading JSON: \(error)")
    }
}

/// Registers the queue changed callback with Rust (fires when remote device adds to queue)
private nonisolated func registerQueueChangedCallback() {
    spotifly_register_queue_changed_callback { jsonPtr in
        handleQueueChangedCallback(jsonPtr)
    }
}

/// Registers the connection state callback with Rust (fires on state changes)
private nonisolated func registerConnectionStateCallback() {
    spotifly_register_connection_state_callback { jsonPtr in
        handleConnectionStateCallback(jsonPtr)
    }
}

/// C callback for connection state updates from Rust
private nonisolated func handleConnectionStateCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleConnectionStateCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Connection state callback: \(jsonString)")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let state = LibrespotConnectionState(
            sessionConnected: json["session_connected"] as? Bool ?? false,
            sessionConnectionId: json["session_connection_id"] as? String,
            spircReady: json["spirc_ready"] as? Bool ?? false,
            deviceId: json["device_id"] as? String,
            deviceName: json["device_name"] as? String ?? "Spotifly",
            reconnectAttempt: (json["reconnect_attempt"] as? NSNumber)?.uint32Value ?? 0,
            lastError: json["last_error"] as? String,
            connectedSinceMs: (json["connected_since_ms"] as? NSNumber)?.uint64Value,
        )

        connectionStateSubject.send(state)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse connection state JSON: \(error)")
    }
}

/// C callback for queue changed notifications from Rust
/// Fires when a remote device adds a track to the queue
private nonisolated func handleQueueChangedCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleQueueChangedCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Queue changed callback: \(jsonString)")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let trackUri = json["track_uri"] as? String ?? ""
        let notification = QueueChangedNotification(trackUri: trackUri)
        queueChangedSubject.send(notification)

    } catch {
        debugLog("SpotifyPlayer", "Failed to parse queue changed JSON: \(error)")
    }
}

/// Registers the set queue callback with Rust (fires when queue is modified)
private nonisolated func registerSetQueueCallback() {
    spotifly_register_set_queue_callback { jsonPtr in
        handleSetQueueCallback(jsonPtr)
    }
}

/// C callback for set queue notifications from Rust
/// Fires when the queue is set/modified or a context is loaded
private nonisolated func handleSetQueueCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleSetQueueCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Set queue callback: \(jsonString.prefix(200))...")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Parse context_uri
        let contextUri = json["context_uri"] as? String ?? ""

        // Parse current_track (optional object with uri and provider)
        var currentTrack: SetQueueTrackInfo?
        if let currentTrackJson = json["current_track"] as? [String: Any] {
            currentTrack = SetQueueTrackInfo(
                uri: currentTrackJson["uri"] as? String ?? "",
                provider: currentTrackJson["provider"] as? String ?? "",
            )
        }

        // Parse next_tracks array
        let nextTracksJson = json["next_tracks"] as? [[String: Any]] ?? []
        let nextTracks = nextTracksJson.map { track in
            SetQueueTrackInfo(
                uri: track["uri"] as? String ?? "",
                provider: track["provider"] as? String ?? "",
            )
        }

        // Parse prev_tracks array
        let prevTracksJson = json["prev_tracks"] as? [[String: Any]] ?? []
        let prevTracks = prevTracksJson.map { track in
            SetQueueTrackInfo(
                uri: track["uri"] as? String ?? "",
                provider: track["provider"] as? String ?? "",
            )
        }

        let notification = SetQueueNotification(
            contextUri: contextUri,
            currentTrack: currentTrack,
            nextTracks: nextTracks,
            prevTracks: prevTracks,
        )
        setQueueSubject.send(notification)

    } catch {
        debugLog("SpotifyPlayer", "Failed to parse set queue JSON: \(error)")
    }
}

/// Registers the session disconnected callback with Rust (fires when dealer connection closes)
private nonisolated func registerSessionDisconnectedCallback() {
    spotifly_register_session_disconnected_callback {
        handleSessionDisconnectedCallback()
    }
}

/// C callback for session disconnection notifications from Rust
/// Fires when the Spotify session disconnects (e.g., idle timeout)
private nonisolated func handleSessionDisconnectedCallback() {
    debugLog("SpotifyPlayer", "Session disconnected event received - triggering reinit")
    DispatchQueue.main.async {
        sessionDisconnectedSubject.send()
    }
}

/// Registers the session connected callback with Rust (fires when session is ready)
private nonisolated func registerSessionConnectedCallback() {
    spotifly_register_session_connected_callback {
        handleSessionConnectedCallback()
    }
}

/// C callback for session connection notifications from Rust
/// Fires when the Spotify session is connected and ready for playback commands
private nonisolated func handleSessionConnectedCallback() {
    debugLog("SpotifyPlayer", "Session connected event received - ready for commands")
    DispatchQueue.main.async {
        sessionConnectedSubject.send()
    }
}

/// Weak reference to the SpotifySession for token requests during reconnection
private nonisolated(unsafe) var tokenProviderSession: SpotifySession?

/// Registers the token request callback with Rust (fires when reconnection needs a fresh token)
private nonisolated func registerTokenRequestCallback() {
    spotifly_register_token_request_callback {
        handleTokenRequestCallback()
    }
}

/// C callback for token request notifications from Rust
/// Fires when Rust's reconnection loop needs a fresh access token
private nonisolated func handleTokenRequestCallback() {
    debugLog("SpotifyPlayer", "Token request received from Rust")
    DispatchQueue.main.async {
        Task { @MainActor in
            guard let session = tokenProviderSession else {
                debugLog("SpotifyPlayer", "No session available for token request")
                return
            }

            let token = await session.validAccessToken()
            debugLog("SpotifyPlayer", "Providing fresh token to Rust (\(token.prefix(20))...)")

            // Call Rust FFI on background thread
            Task.detached {
                token.withCString { tokenPtr in
                    spotifly_set_token(tokenPtr)
                }
            }
        }
    }
}

/// Registers the session client changed callback with Rust
private nonisolated func registerSessionClientChangedCallback() {
    spotifly_register_session_client_changed_callback { jsonPtr in
        handleSessionClientChangedCallback(jsonPtr)
    }
}

/// C callback for session client changed notifications from Rust
/// Fires when the controlling Spotify client changes
private nonisolated func handleSessionClientChangedCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleSessionClientChangedCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Session client changed: \(jsonString)")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let notification = SessionClientChangedNotification(
            clientId: json["client_id"] as? String ?? "",
            clientName: json["client_name"] as? String ?? "",
            clientBrandName: json["client_brand_name"] as? String ?? "",
            clientModelName: json["client_model_name"] as? String ?? "",
        )

        debugLog(
            "SpotifyPlayer",
            "Session client: \(notification.clientName) (\(notification.clientBrandName) \(notification.clientModelName))",
        )

        sessionClientChangedSubject.send(notification)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse session client changed JSON: \(error)")
    }
}

/// C callback for state update notifications from Rust
private nonisolated func handleStateUpdateCallback() {
    debugLog("SpotifyPlayer", "State update callback triggered")
}

/// C callback for playback state updates from Rust
/// Uses manual JSON parsing to avoid Decodable actor isolation issues
private nonisolated func handlePlaybackStateCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    debugLog("SpotifyPlayer", "handlePlaybackStateCallback called")

    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handlePlaybackStateCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "handlePlaybackStateCallback received JSON (\(jsonString.count) chars)")

    guard let data = jsonString.data(using: .utf8) else {
        debugLog("SpotifyPlayer", "handlePlaybackStateCallback: failed to convert JSON to data")
        return
    }

    do {
        // Use JSONSerialization instead of Decodable to avoid actor isolation issues
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog("SpotifyPlayer", "handlePlaybackStateCallback: JSON is not a dictionary")
            return
        }

        let state = PlaybackState(
            isPlaying: json["is_playing"] as? Bool ?? false,
            isPaused: json["is_paused"] as? Bool ?? false,
            trackUri: json["track_uri"] as? String ?? "",
            positionMs: (json["position_ms"] as? NSNumber)?.int64Value ?? 0,
            durationMs: (json["duration_ms"] as? NSNumber)?.int64Value ?? 0,
            shuffle: json["shuffle"] as? Bool ?? false,
            repeatTrack: json["repeat_track"] as? Bool ?? false,
            repeatContext: json["repeat_context"] as? Bool ?? false,
            timestampMs: (json["timestamp_ms"] as? NSNumber)?.int64Value ?? 0,
        )

        debugLog("SpotifyPlayer", "PlaybackState: playing=\(state.isPlaying), paused=\(state.isPaused), pos=\(state.positionMs)ms, dur=\(state.durationMs)ms, shuffle=\(state.shuffle), repeatTrack=\(state.repeatTrack), repeatContext=\(state.repeatContext)")

        playbackStateSubject.send(state)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse playback state JSON: \(error)")
        debugLog("SpotifyPlayer", "JSON preview: \(String(jsonString.prefix(500)))")
    }
}

/// Parses a queue item from a JSON dictionary (manual parsing to avoid Decodable actor isolation issues)
private nonisolated func parseQueueItem(from dict: [String: Any]) -> QueueItem? {
    guard let uri = dict["uri"] as? String else { return nil }
    return QueueItem(
        id: uri,
        uri: uri,
        name: dict["name"] as? String ?? "",
        artistName: dict["artist"] as? String ?? "",
        imageURLString: dict["image_url"] as? String ?? "",
        durationMs: (dict["duration_ms"] as? NSNumber)?.uint32Value ?? 0,
        albumId: nil,
        artistId: nil,
        externalUrl: nil,
        provider: dict["provider"] as? String ?? "unavailable",
    )
}

/// C callback for queue updates from Rust
/// Uses manual JSON parsing to avoid Decodable actor isolation issues
private nonisolated func handleQueueCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    debugLog("SpotifyPlayer", "handleQueueCallback called")

    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleQueueCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "handleQueueCallback received JSON (\(jsonString.count) chars)")

    guard let data = jsonString.data(using: .utf8) else {
        debugLog("SpotifyPlayer", "handleQueueCallback: failed to convert JSON to data")
        return
    }

    do {
        // Use JSONSerialization instead of Decodable to avoid actor isolation issues
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            debugLog("SpotifyPlayer", "handleQueueCallback: JSON is not a dictionary")
            return
        }

        // Parse current track
        let currentTrack: QueueItem? = if let trackDict = json["track"] as? [String: Any] {
            parseQueueItem(from: trackDict)
        } else {
            nil
        }

        // Parse next tracks
        let nextTracks: [QueueItem] = if let nextArray = json["next_tracks"] as? [[String: Any]] {
            nextArray.compactMap { parseQueueItem(from: $0) }
        } else {
            []
        }

        // Parse previous tracks
        let prevTracks: [QueueItem] = if let prevArray = json["prev_tracks"] as? [[String: Any]] {
            prevArray.compactMap { parseQueueItem(from: $0) }
        } else {
            []
        }

        let state = QueueState(
            currentTrack: currentTrack,
            nextTracks: nextTracks,
            previousTracks: prevTracks,
        )

        let currentName = state.currentTrack?.name ?? "none"
        let nextCount = state.nextTracks.count
        let prevCount = state.previousTracks?.count ?? 0
        debugLog("SpotifyPlayer", "handleQueueCallback: current='\(currentName)', next=\(nextCount), prev=\(prevCount)")

        queueSubject.send(state)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse queue JSON: \(error)")
        debugLog("SpotifyPlayer", "JSON preview: \(String(jsonString.prefix(500)))")
    }
}

/// Errors that can occur during playback
enum SpotifyPlayerError: Error, LocalizedError, Sendable {
    case initializationFailed
    case playbackFailed
    case notInitialized
    case queueFetchFailed

    var errorDescription: String? {
        switch self {
        case .initializationFailed:
            "Failed to initialize player"
        case .playbackFailed:
            "Failed to play track"
        case .notInitialized:
            "Player not initialized"
        case .queueFetchFailed:
            "Failed to fetch queue"
        }
    }
}

/// Global subject for session disconnection (needs reinit)
private nonisolated(unsafe) let sessionDisconnectedSubject = PassthroughSubject<Void, Never>()

/// Global subject for session connection (ready for commands)
private nonisolated(unsafe) let sessionConnectedSubject = PassthroughSubject<Void, Never>()

/// Swift wrapper for the Rust librespot playback functionality
enum SpotifyPlayer {
    /// Initializes the player with the given access token.
    /// Must be called before any playback operations.
    @SpotifyAuthActor
    static func initialize(accessToken: String) async throws {
        // Register callbacks (via nonisolated helpers to avoid actor isolation issues)
        registerQueueCallback()
        registerPlaybackStateCallback()
        registerStateUpdateCallback()
        registerVolumeCallback()
        registerLoadingCallback()
        registerQueueChangedCallback()
        registerSetQueueCallback()
        registerSessionDisconnectedCallback()
        registerSessionConnectedCallback()
        registerSessionClientChangedCallback()
        registerConnectionStateCallback()
        registerTokenRequestCallback()

        // Sync playback settings from UserDefaults before initializing
        syncSettingsFromUserDefaults()

        // Clean up any previous session state before initializing
        // Full cleanup is necessary because Session instances cannot be reused after disconnection
        await Task.detached {
            spotifly_cleanup()
        }.value

        let result = await Task.detached {
            accessToken.withCString { tokenPtr in
                spotifly_init_player(tokenPtr)
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.initializationFailed
        }
    }

    /// Sets the session to use for token requests during automatic reconnection.
    /// Call this after initializing the player with the session that can provide fresh tokens.
    @MainActor
    static func setTokenProvider(_ session: SpotifySession) {
        tokenProviderSession = session
    }

    /// Returns a publisher for queue updates.
    static var queue: AnyPublisher<QueueState?, Never> {
        queueSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for playback state updates.
    static var playbackState: AnyPublisher<PlaybackState?, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for remote volume changes (0-65535).
    /// Subscribe to this to update the UI when volume is changed from another device.
    static var volumeChanged: AnyPublisher<UInt16, Never> {
        volumeSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for loading notifications.
    /// Fires early (~180ms) when a track starts loading, before metadata is fetched.
    /// Use this for faster Now Playing updates when playing from remote devices.
    static var loading: AnyPublisher<LoadingNotification, Never> {
        loadingSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for queue changed notifications.
    /// Fires when a remote device adds a track to the queue.
    static var queueChanged: AnyPublisher<QueueChangedNotification, Never> {
        queueChangedSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for set queue notifications.
    /// Fires when the queue is set/modified (e.g., from mobile app set_queue command).
    static var setQueue: AnyPublisher<SetQueueNotification, Never> {
        setQueueSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher that emits when the session is disconnected and needs reinitialization.
    /// Subscribe to this to trigger automatic reconnection with a fresh token.
    static var sessionDisconnected: AnyPublisher<Void, Never> {
        sessionDisconnectedSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher that emits when the session is connected and ready for commands.
    /// Subscribe to this to enable playback controls after initialization or reconnection.
    static var sessionConnected: AnyPublisher<Void, Never> {
        sessionConnectedSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for session client changed notifications.
    /// Fires when the controlling Spotify client changes (e.g., which app initiated playback).
    static var sessionClientChanged: AnyPublisher<SessionClientChangedNotification, Never> {
        sessionClientChangedSubject.eraseToAnyPublisher()
    }

    /// Returns whether the session is currently connected and ready for playback commands.
    static var isSessionConnected: Bool {
        spotifly_is_session_connected() == 1
    }

    /// Forces a reconnection to Spotify servers.
    /// Use this after system wake to ensure a fresh connection before playback.
    /// Returns true if reconnection was triggered, false if already reconnecting or no session.
    @discardableResult
    static func forceReconnect() -> Bool {
        let result = spotifly_force_reconnect()
        return result == 0
    }

    /// Returns a publisher for connection state updates.
    /// Subscribe to this to update the connection status dashboard.
    static var connectionState: AnyPublisher<LibrespotConnectionState?, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    /// Returns the current connection state synchronously.
    /// Use this for initial UI display or one-time queries.
    static func getConnectionState() -> LibrespotConnectionState? {
        let ptr = spotifly_get_connection_state()
        guard ptr != nil else { return nil }
        defer { spotifly_free_string(ptr) }

        let jsonString = String(cString: ptr!)
        guard let data = jsonString.data(using: String.Encoding.utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return LibrespotConnectionState(
            sessionConnected: json["session_connected"] as? Bool ?? false,
            sessionConnectionId: json["session_connection_id"] as? String,
            spircReady: json["spirc_ready"] as? Bool ?? false,
            deviceId: json["device_id"] as? String,
            deviceName: json["device_name"] as? String ?? "Spotifly",
            reconnectAttempt: (json["reconnect_attempt"] as? NSNumber)?.uint32Value ?? 0,
            lastError: json["last_error"] as? String,
            connectedSinceMs: (json["connected_since_ms"] as? NSNumber)?.uint64Value,
        )
    }

    /// Syncs playback settings from UserDefaults to the Rust player
    private nonisolated static func syncSettingsFromUserDefaults() {
        let bitrateRawValue = UserDefaults.standard.object(forKey: "streamingBitrate") as? Int ?? 1
        let gaplessEnabled = UserDefaults.standard.object(forKey: "gaplessPlayback") as? Bool ?? true
        let savedVolume = UserDefaults.standard.double(forKey: "playbackVolume")
        // Convert 0.0-1.0 to 0-65535, default to 50% if not set
        let volumeU16 = savedVolume > 0 ? UInt16(savedVolume * 65535.0) : 65535 / 2

        // Call FFI directly to avoid actor isolation issues
        spotifly_set_bitrate(UInt8(min(max(bitrateRawValue, 0), 2)))
        spotifly_set_gapless(gaplessEnabled)
        spotifly_set_initial_volume(volumeU16)
    }

    /// Plays content by its Spotify URI or URL.
    /// Supports albums, playlists, and artists (context URIs).
    /// - Parameters:
    ///   - uriOrUrl: Spotify URI or URL (e.g., "spotify:album:xxx")
    ///   - trackIndex: Track index to start at (-1 = from beginning, 0+ = specific track)
    @SpotifyAuthActor
    static func play(uriOrUrl: String, trackIndex: Int = -1) async throws {
        let result = await Task.detached {
            uriOrUrl.withCString { ptr in
                spotifly_play_uri(ptr, Int32(trackIndex))
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Plays a track by its Spotify track ID.
    @SpotifyAuthActor
    static func playTrack(trackId: String) async throws {
        let trackUri = "spotify:track:\(trackId)"
        try await play(uriOrUrl: trackUri)
    }

    /// Plays multiple tracks in sequence.
    /// - Parameter trackUris: Array of Spotify track URIs
    @SpotifyAuthActor
    static func playTracks(_ trackUris: [String]) async throws {
        guard !trackUris.isEmpty else {
            throw SpotifyPlayerError.playbackFailed
        }

        // Convert array to JSON
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(trackUris),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            throw SpotifyPlayerError.playbackFailed
        }

        let result = await Task.detached {
            jsonString.withCString { ptr in
                spotifly_play_tracks(ptr)
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Pauses playback.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    static func pause() {
        Task.detached(priority: .userInitiated) {
            spotifly_pause()
        }
    }

    /// Clears any buffered audio samples.
    /// Call this before sleep to prevent stale audio playing on wake.
    /// Dispatched to background thread as this explicitly blocks until buffer is flushed.
    static func clearAudioBuffer() {
        Task.detached(priority: .userInitiated) {
            spotifly_clear_audio_buffer()
        }
    }

    /// Resumes playback.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    static func resume() {
        Task.detached(priority: .userInitiated) {
            spotifly_resume()
        }
    }

    /// Stops playback.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    static func stop() {
        Task.detached(priority: .userInitiated) {
            spotifly_stop()
        }
    }

    /// Shuts down the Spirc connection and sends goodbye to other devices.
    /// Call this when the app is quitting to properly disconnect from Spotify Connect.
    /// Dispatched to background thread to avoid blocking the main thread.
    static func shutdown() {
        Task.detached(priority: .userInitiated) {
            spotifly_shutdown()
        }
    }

    /// Disconnects from Spotify Connect without preventing future reconnection.
    /// Use this before system sleep - the device disappears from Spotify immediately,
    /// but forceReconnect() can still bring it back on wake.
    /// Dispatched to background thread to avoid blocking the main thread.
    static func disconnect() {
        Task.detached(priority: .userInitiated) {
            spotifly_disconnect()
        }
    }

    /// Returns whether the player is currently playing.
    static var isPlaying: Bool {
        spotifly_is_playing() == 1
    }

    /// Returns whether Spirc is initialized and connected to Spotify Connect.
    static var isSpircReady: Bool {
        spotifly_is_spirc_ready() == 1
    }

    /// Returns whether this device is the active Spotify Connect device.
    /// When false, playback controls should use Web API instead of Spirc.
    static var isActiveDevice: Bool {
        spotifly_is_active_device() == 1
    }

    /// Returns the current playback position in milliseconds.
    /// This is the actual position from the player, not an estimate.
    static var positionMs: UInt32 {
        spotifly_get_position_ms()
    }

    /// Skips to the next track in the queue.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    /// State updates come back via Mercury callback.
    static func next() {
        Task.detached(priority: .userInitiated) {
            spotifly_next()
        }
    }

    /// Skips to the previous track in the queue.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    /// State updates come back via Mercury callback.
    static func previous() {
        Task.detached(priority: .userInitiated) {
            spotifly_previous()
        }
    }

    /// Seeks to the given position in milliseconds.
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    /// State updates come back via Mercury callback.
    static func seek(positionMs: UInt32) {
        Task.detached(priority: .userInitiated) {
            spotifly_seek(positionMs)
        }
    }

    /// Sets the playback volume (0.0 - 1.0).
    /// Dispatched to background thread to avoid blocking the main thread on Spirc mutex.
    static func setVolume(_ volume: Double) {
        let volumeU16 = UInt16(max(0, min(1, volume)) * 65535.0)
        Task.detached(priority: .userInitiated) {
            spotifly_set_volume(volumeU16)
        }
    }

    /// Plays radio for a seed track.
    /// Dispatched to background thread as this blocks on a network request.
    /// - Parameter trackUri: The Spotify track URI to use as seed
    static func playRadio(trackUri: String) {
        Task.detached(priority: .userInitiated) {
            _ = trackUri.withCString { ptr in
                spotifly_play_radio(ptr)
            }
        }
    }

    /// Transfers playback from another Spotify Connect device to this local player.
    /// Uses the native Spotify Connect protocol via Spirc for seamless handoff.
    /// Dispatched to background thread to avoid blocking the main thread.
    static func transferToLocal() {
        Task.detached(priority: .userInitiated) {
            spotifly_transfer_to_local()
        }
    }

    /// Transfers playback from this local player to another device.
    /// Uses the native Spotify Connect protocol via SpClient for seamless handoff.
    /// Dispatched to background thread to avoid blocking the main thread.
    /// - Parameter deviceId: The target device ID to transfer playback to
    static func transferPlayback(to deviceId: String) {
        Task.detached(priority: .userInitiated) {
            _ = deviceId.withCString { ptr in
                spotifly_transfer_playback(ptr)
            }
        }
    }

    /// Adds an item to the queue via Spirc.
    /// Dispatched to background thread to avoid blocking the main thread.
    /// - Parameter uri: The Spotify URI to add to the queue (track, episode, etc.)
    static func addToQueue(uri: String) {
        Task.detached(priority: .userInitiated) {
            _ = uri.withCString { ptr in
                spotifly_add_to_queue(ptr)
            }
        }
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

    /// Sets the streaming bitrate. Takes effect on next player initialization.
    static func setBitrate(_ bitrate: Bitrate) {
        spotifly_set_bitrate(bitrate.rawValue)
    }

    /// Gets the current bitrate setting.
    static var bitrate: Bitrate {
        Bitrate(rawValue: spotifly_get_bitrate()) ?? .normal
    }

    /// Sets gapless playback. Takes effect on next player initialization.
    static func setGapless(_ enabled: Bool) {
        spotifly_set_gapless(enabled)
    }

    /// Gets the current gapless playback setting.
    static var gapless: Bool {
        spotifly_get_gapless()
    }
}
