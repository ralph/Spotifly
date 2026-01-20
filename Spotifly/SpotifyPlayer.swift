//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the librespot playback functionality
//  STUB IMPLEMENTATION - FFI calls replaced with no-ops
//

import Combine
import Foundation

// MARK: - Stub FFI Functions (nonisolated to match original FFI behavior)

/// Stub: Initialize the player with an access token
private nonisolated func spotifly_init_player(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: init_player called")
    return 0
}

/// Stub: Register queue callback
private nonisolated func spotifly_register_queue_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_queue_callback called")
}

/// Stub: Register playback state callback
private nonisolated func spotifly_register_playback_state_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_playback_state_callback called")
}

/// Stub: Register state update callback
private nonisolated func spotifly_register_state_update_callback(_: (@convention(c) () -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_state_update_callback called")
}

/// Stub: Register volume callback
private nonisolated func spotifly_register_volume_callback(_: (@convention(c) (UInt16) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_volume_callback called")
}

/// Stub: Register loading callback
private nonisolated func spotifly_register_loading_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_loading_callback called")
}

/// Stub: Register queue changed callback
private nonisolated func spotifly_register_queue_changed_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_queue_changed_callback called")
}

/// Stub: Register session disconnected callback
private nonisolated func spotifly_register_session_disconnected_callback(_: (@convention(c) () -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_session_disconnected_callback called")
}

/// Stub: Register session connected callback
private nonisolated func spotifly_register_session_connected_callback(_: (@convention(c) () -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_session_connected_callback called")
}

/// Stub: Register session client changed callback
private nonisolated func spotifly_register_session_client_changed_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_session_client_changed_callback called")
}

/// Stub: Register connection state callback
private nonisolated func spotifly_register_connection_state_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_connection_state_callback called")
}

/// Stub: Register context loaded callback
private nonisolated func spotifly_register_context_loaded_callback(_: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    debugLog("SpotifyPlayer", "STUB: register_context_loaded_callback called")
}

/// Stub: Cleanup player
private nonisolated func spotifly_cleanup() {
    debugLog("SpotifyPlayer", "STUB: cleanup called")
}

/// Stub: Soft cleanup (preserve player during reconnect)
private nonisolated func spotifly_soft_cleanup() {
    debugLog("SpotifyPlayer", "STUB: soft_cleanup called")
}

/// Stub: Play URI
private nonisolated func spotifly_play_uri(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: play_uri called")
    return 0
}

/// Stub: Play multiple tracks
private nonisolated func spotifly_play_tracks(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: play_tracks called")
    return 0
}

/// Stub: Pause playback
private nonisolated func spotifly_pause() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: pause called")
    return 0
}

/// Stub: Resume playback
private nonisolated func spotifly_resume() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: resume called")
    return 0
}

/// Stub: Stop playback
private nonisolated func spotifly_stop() {
    debugLog("SpotifyPlayer", "STUB: stop called")
}

/// Stub: Shutdown spirc
private nonisolated func spotifly_shutdown() {
    debugLog("SpotifyPlayer", "STUB: shutdown called")
}

/// Stub: Check if playing
private nonisolated func spotifly_is_playing() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: is_playing called")
    return 0
}

/// Stub: Check if spirc is ready
private nonisolated func spotifly_is_spirc_ready() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: is_spirc_ready called")
    return 0
}

/// Stub: Check if session is connected
private nonisolated func spotifly_is_session_connected() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: is_session_connected called")
    return 0
}

/// Stub: Get playback position
private nonisolated func spotifly_get_position_ms() -> UInt32 {
    debugLog("SpotifyPlayer", "STUB: get_position_ms called")
    return 0
}

/// Stub: Skip to next track
private nonisolated func spotifly_next() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: next called")
    return 0
}

/// Stub: Skip to previous track
private nonisolated func spotifly_previous() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: previous called")
    return 0
}

/// Stub: Seek to position
private nonisolated func spotifly_seek(_: UInt32) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: seek called")
    return 0
}

/// Stub: Set volume
private nonisolated func spotifly_set_volume(_: UInt16) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: set_volume called")
    return 0
}

/// Stub: Play radio for seed track
private nonisolated func spotifly_play_radio(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: play_radio called")
    return 0
}

/// Stub: Transfer playback to local device
private nonisolated func spotifly_transfer_to_local() -> Int32 {
    debugLog("SpotifyPlayer", "STUB: transfer_to_local called")
    return 0
}

/// Stub: Transfer playback to another device
private nonisolated func spotifly_transfer_playback(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: transfer_playback called")
    return 0
}

/// Stub: Add item to queue
private nonisolated func spotifly_add_to_queue(_: UnsafePointer<CChar>?) -> Int32 {
    debugLog("SpotifyPlayer", "STUB: add_to_queue called")
    return 0
}

/// Stub: Set bitrate
private nonisolated func spotifly_set_bitrate(_: UInt8) {
    debugLog("SpotifyPlayer", "STUB: set_bitrate called")
}

/// Stub: Get bitrate
private nonisolated func spotifly_get_bitrate() -> UInt8 {
    debugLog("SpotifyPlayer", "STUB: get_bitrate called")
    return 1 // normal
}

/// Stub: Set gapless playback
private nonisolated func spotifly_set_gapless(_: Bool) {
    debugLog("SpotifyPlayer", "STUB: set_gapless called")
}

/// Stub: Get gapless playback
private nonisolated func spotifly_get_gapless() -> Bool {
    debugLog("SpotifyPlayer", "STUB: get_gapless called")
    return true
}

/// Stub: Set initial volume
private nonisolated func spotifly_set_initial_volume(_: UInt16) {
    debugLog("SpotifyPlayer", "STUB: set_initial_volume called")
}

/// Stub: Get connection state as JSON
private nonisolated func spotifly_get_connection_state() -> UnsafeMutablePointer<CChar>? {
    debugLog("SpotifyPlayer", "STUB: get_connection_state called")
    return nil
}

/// Stub: Free string allocated by Rust
private nonisolated func spotifly_free_string(_: UnsafeMutablePointer<CChar>?) {
    debugLog("SpotifyPlayer", "STUB: free_string called")
}

// MARK: - Data Types

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
    var imageURL: URL? { URL(string: imageURLString) }

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

/// Context loaded notification containing track URIs when a context (playlist/album) is loaded
struct ContextLoadedNotification: Sendable {
    nonisolated let contextUri: String
    nonisolated let currentTrackUri: String?
    nonisolated let currentTrackProvider: String?
    nonisolated let nextTrackUris: [String]
    nonisolated let nextTrackProviders: [String]
    nonisolated let prevTrackUris: [String]
    nonisolated let prevTrackProviders: [String]
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

/// Global subject for connection state updates (nonisolated for C callback access)
private nonisolated(unsafe) let connectionStateSubject = CurrentValueSubject<LibrespotConnectionState?, Never>(nil)

/// Global subject for context loaded notifications (nonisolated for C callback access)
private nonisolated(unsafe) let contextLoadedSubject = PassthroughSubject<ContextLoadedNotification, Never>()

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

/// Registers the context loaded callback with Rust (fires when a context is loaded)
private nonisolated func registerContextLoadedCallback() {
    spotifly_register_context_loaded_callback { jsonPtr in
        handleContextLoadedCallback(jsonPtr)
    }
}

/// C callback for context loaded notifications from Rust
/// Fires immediately when a context (playlist, album, etc.) is loaded locally
private nonisolated func handleContextLoadedCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let jsonPtr else {
        debugLog("SpotifyPlayer", "handleContextLoadedCallback: jsonPtr is nil")
        return
    }

    let jsonString = String(cString: jsonPtr)
    debugLog("SpotifyPlayer", "Context loaded callback: \(jsonString.prefix(200))...")

    guard let data = jsonString.data(using: .utf8) else {
        return
    }

    do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let notification = ContextLoadedNotification(
            contextUri: json["context_uri"] as? String ?? "",
            currentTrackUri: json["current_track_uri"] as? String,
            currentTrackProvider: json["current_track_provider"] as? String,
            nextTrackUris: json["next_track_uris"] as? [String] ?? [],
            nextTrackProviders: json["next_track_providers"] as? [String] ?? [],
            prevTrackUris: json["prev_track_uris"] as? [String] ?? [],
            prevTrackProviders: json["prev_track_providers"] as? [String] ?? [],
        )

        debugLog(
            "SpotifyPlayer",
            "Context loaded: \(notification.contextUri), next=\(notification.nextTrackUris.count), prev=\(notification.prevTrackUris.count)",
        )

        contextLoadedSubject.send(notification)
    } catch {
        debugLog("SpotifyPlayer", "Failed to parse context loaded JSON: \(error)")
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
    sessionDisconnectedSubject.send()
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
    sessionConnectedSubject.send()
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
    case sessionDisconnected

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
        case .sessionDisconnected:
            "Session disconnected, needs reinitialization"
        }
    }
}

/// Global subject for session disconnection (needs reinit)
private nonisolated(unsafe) let sessionDisconnectedSubject = PassthroughSubject<Void, Never>()

/// Global subject for session connection (ready for commands)
private nonisolated(unsafe) let sessionConnectedSubject = PassthroughSubject<Void, Never>()

/// Error code returned by Rust when session is disconnected
private let errorNeedsReinit: Int32 = -2

/// Swift wrapper for the Rust librespot playback functionality
enum SpotifyPlayer {
    /// Flag indicating soft reconnect mode (preserves Player during reinit)
    private nonisolated(unsafe) static var softReconnectMode = false

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
        registerSessionDisconnectedCallback()
        registerSessionConnectedCallback()
        registerSessionClientChangedCallback()
        registerConnectionStateCallback()
        registerContextLoadedCallback()

        // Sync playback settings from UserDefaults before initializing
        syncSettingsFromUserDefaults()

        // Clean up any previous session state before initializing
        // Skip full cleanup in soft reconnect mode - Rust soft_cleanup already cleared Session/Spirc
        // and we want to preserve the Player for uninterrupted audio
        if softReconnectMode {
            debugLog("SpotifyPlayer", "Soft reconnect mode - skipping full cleanup to preserve Player")
            softReconnectMode = false // Reset flag after use
        } else {
            // Full cleanup - necessary because Session instances cannot be reused after disconnection
            await Task.detached {
                spotifly_cleanup()
            }.value
        }

        let result = await Task.detached {
            accessToken.withCString { tokenPtr in
                spotifly_init_player(tokenPtr)
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.initializationFailed
        }
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

    /// Returns a publisher for connection state updates.
    /// Subscribe to this to update the connection status dashboard.
    static var connectionState: AnyPublisher<LibrespotConnectionState?, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher for context loaded notifications.
    /// Fires immediately when a context (playlist, album, etc.) is loaded locally.
    /// Contains the full list of track URIs in the context.
    static var contextLoaded: AnyPublisher<ContextLoadedNotification, Never> {
        contextLoadedSubject.eraseToAnyPublisher()
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
    /// Supports tracks, albums, playlists, and artists.
    @SpotifyAuthActor
    static func play(uriOrUrl: String) async throws {
        let result = await Task.detached {
            uriOrUrl.withCString { ptr in
                spotifly_play_uri(ptr)
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
    /// Emits on `sessionDisconnected` if the session needs reinitialization.
    static func pause() {
        let result = spotifly_pause()
        if result == errorNeedsReinit {
            sessionDisconnectedSubject.send()
        }
    }

    /// Resumes playback.
    /// Emits on `sessionDisconnected` if the session needs reinitialization.
    static func resume() {
        let result = spotifly_resume()
        if result == errorNeedsReinit {
            sessionDisconnectedSubject.send()
        }
    }

    /// Stops playback.
    static func stop() {
        spotifly_stop()
    }

    /// Shuts down the Spirc connection and sends goodbye to other devices.
    /// Call this when the app is quitting to properly disconnect from Spotify Connect.
    static func shutdown() {
        spotifly_shutdown()
    }

    /// Soft cleanup - preserves Player and Mixer for uninterrupted playback.
    /// Only clears Session and Spirc, allowing reconnection without audio gap.
    /// Call this instead of full cleanup when you want to preserve current playback.
    static func softCleanup() {
        softReconnectMode = true
        spotifly_soft_cleanup()
    }

    /// Returns whether the player is currently playing.
    static var isPlaying: Bool {
        spotifly_is_playing() == 1
    }

    /// Returns whether Spirc is initialized and connected to Spotify Connect.
    static var isSpircReady: Bool {
        spotifly_is_spirc_ready() == 1
    }

    /// Returns the current playback position in milliseconds.
    /// This is the actual position from the player, not an estimate.
    static var positionMs: UInt32 {
        spotifly_get_position_ms()
    }

    /// Skips to the next track in the queue.
    /// Throws `sessionDisconnected` if the session needs reinitialization.
    static func next() throws {
        let result = spotifly_next()
        if result == errorNeedsReinit {
            throw SpotifyPlayerError.sessionDisconnected
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Skips to the previous track in the queue.
    /// Throws `sessionDisconnected` if the session needs reinitialization.
    static func previous() throws {
        let result = spotifly_previous()
        if result == errorNeedsReinit {
            throw SpotifyPlayerError.sessionDisconnected
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Seeks to the given position in milliseconds.
    /// Throws `sessionDisconnected` if the session needs reinitialization.
    static func seek(positionMs: UInt32) throws {
        let result = spotifly_seek(positionMs)
        if result == errorNeedsReinit {
            throw SpotifyPlayerError.sessionDisconnected
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Sets the playback volume (0.0 - 1.0).
    /// Emits on `sessionDisconnected` if the session needs reinitialization.
    static func setVolume(_ volume: Double) {
        let volumeU16 = UInt16(max(0, min(1, volume)) * 65535.0)
        let result = spotifly_set_volume(volumeU16)
        if result == errorNeedsReinit {
            sessionDisconnectedSubject.send()
        }
    }

    /// Plays radio for a seed track.
    /// - Parameter trackUri: The Spotify track URI to use as seed
    static func playRadio(trackUri: String) throws {
        let result = trackUri.withCString { ptr in
            spotifly_play_radio(ptr)
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Transfers playback from another Spotify Connect device to this local player.
    /// Uses the native Spotify Connect protocol via Spirc for seamless handoff.
    static func transferToLocal() throws {
        let result = spotifly_transfer_to_local()
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Transfers playback from this local player to another device.
    /// Uses the native Spotify Connect protocol via SpClient for seamless handoff.
    /// - Parameter deviceId: The target device ID to transfer playback to
    static func transferPlayback(to deviceId: String) throws {
        let result = deviceId.withCString { ptr in
            spotifly_transfer_playback(ptr)
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Adds an item to the queue via Spirc.
    /// - Parameter uri: The Spotify URI to add to the queue (track, episode, etc.)
    static func addToQueue(uri: String) throws {
        let result = uri.withCString { ptr in
            spotifly_add_to_queue(ptr)
        }
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    // MARK: - Playback Settings

    /// Streaming bitrate options
    enum Bitrate: UInt8, CaseIterable, Identifiable {
        case low = 0 // 96 kbps
        case normal = 1 // 160 kbps (default)
        case high = 2 // 320 kbps

        var id: UInt8 { rawValue }

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
