//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the librespot playback functionality
//  Now delegates to LibrespotClient (pure Swift implementation)
//

import Combine
import Foundation

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

/// Global subject for session client changed notifications
private nonisolated(unsafe) let sessionClientChangedSubject = PassthroughSubject<SessionClientChangedNotification, Never>()

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

/// Swift wrapper for the Rust librespot playback functionality
/// Now delegates to LibrespotClient for actual implementation
enum SpotifyPlayer {
    /// Flag indicating soft reconnect mode (preserves Player during reinit)
    private nonisolated(unsafe) static var softReconnectMode = false

    /// Reference to the Swift librespot client
    private static var client: LibrespotClient { LibrespotClient.shared }

    /// Subscriptions for forwarding LibrespotClient events
    private nonisolated(unsafe) static var subscriptions: Set<AnyCancellable> = []

    /// Initializes the player with the given access token.
    /// Must be called before any playback operations.
    @SpotifyAuthActor
    static func initialize(accessToken: String) async throws {
        debugLog("SpotifyPlayer", "Initializing via LibrespotClient...")

        // Wire up LibrespotClient publishers to global subjects (on main actor)
        await MainActor.run {
            setupPublisherForwarding()
        }

        // Initialize LibrespotClient
        try await client.initialize(accessToken: accessToken)

        debugLog("SpotifyPlayer", "LibrespotClient initialization complete")
    }

    /// Set up forwarding from LibrespotClient publishers to global subjects
    @MainActor
    private static func setupPublisherForwarding() {
        // Clear any existing subscriptions
        subscriptions.removeAll()

        // Forward queue updates
        client.queue
            .sink { state in queueSubject.send(state) }
            .store(in: &subscriptions)

        // Forward playback state updates
        client.playbackState
            .sink { state in playbackStateSubject.send(state) }
            .store(in: &subscriptions)

        // Forward volume changes
        client.volumeChanged
            .sink { volume in volumeSubject.send(volume) }
            .store(in: &subscriptions)

        // Forward loading notifications
        client.loading
            .sink { notification in loadingSubject.send(notification) }
            .store(in: &subscriptions)

        // Forward queue changed notifications
        client.queueChanged
            .sink { notification in queueChangedSubject.send(notification) }
            .store(in: &subscriptions)

        // Forward connection state updates
        client.connectionStatePublisher
            .sink { state in connectionStateSubject.send(state) }
            .store(in: &subscriptions)

        // Forward context loaded notifications
        client.contextLoaded
            .sink { notification in contextLoadedSubject.send(notification) }
            .store(in: &subscriptions)

        // Forward session disconnected
        client.sessionDisconnected
            .sink { sessionDisconnectedSubject.send() }
            .store(in: &subscriptions)

        // Forward session connected
        client.sessionConnected
            .sink { sessionConnectedSubject.send() }
            .store(in: &subscriptions)

        // Forward session client changed
        client.sessionClientChanged
            .sink { notification in sessionClientChangedSubject.send(notification) }
            .store(in: &subscriptions)
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
        client.isSessionConnected
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
        client.getConnectionState()
    }

    /// Plays content by its Spotify URI or URL.
    /// Supports tracks, albums, playlists, and artists.
    @SpotifyAuthActor
    static func play(uriOrUrl: String) async throws {
        try await client.play(uri: uriOrUrl)
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
        try await client.playTracks(trackUris)
    }

    /// Pauses playback.
    static func pause() {
        Task {
            await client.pause()
        }
    }

    /// Resumes playback.
    static func resume() {
        Task {
            await client.resume()
        }
    }

    /// Stops playback.
    static func stop() {
        Task {
            await client.stop()
        }
    }

    /// Shuts down the Spirc connection and sends goodbye to other devices.
    /// Call this when the app is quitting to properly disconnect from Spotify Connect.
    static func shutdown() {
        Task {
            await client.shutdown()
        }
    }

    /// Soft cleanup - preserves Player and Mixer for uninterrupted playback.
    /// Only clears Session and Spirc, allowing reconnection without audio gap.
    /// Call this instead of full cleanup when you want to preserve current playback.
    static func softCleanup() {
        softReconnectMode = true
        Task {
            await client.softCleanup()
        }
    }

    /// Returns whether the player is currently playing.
    static var isPlaying: Bool {
        client.isPlaying
    }

    /// Returns whether Spirc is initialized and connected to Spotify Connect.
    static var isSpircReady: Bool {
        client.isSpircReady
    }

    /// Returns the current playback position in milliseconds.
    /// This is the actual position from the player, not an estimate.
    static var positionMs: UInt32 {
        client.positionMs
    }

    /// Skips to the next track in the queue.
    static func next() throws {
        Task {
            try await client.next()
        }
    }

    /// Skips to the previous track in the queue.
    static func previous() throws {
        Task {
            try await client.previous()
        }
    }

    /// Seeks to the given position in milliseconds.
    static func seek(positionMs: UInt32) throws {
        Task {
            try await client.seek(positionMs: positionMs)
        }
    }

    /// Sets the playback volume (0.0 - 1.0).
    static func setVolume(_ volume: Double) {
        Task {
            await client.setVolume(volume)
        }
    }

    /// Plays radio for a seed track.
    /// - Parameter trackUri: The Spotify track URI to use as seed
    static func playRadio(trackUri: String) throws {
        Task {
            try await client.playRadio(trackUri: trackUri)
        }
    }

    /// Transfers playback from another Spotify Connect device to this local player.
    /// Uses the native Spotify Connect protocol via Spirc for seamless handoff.
    static func transferToLocal() throws {
        Task {
            try await client.transferToLocal()
        }
    }

    /// Transfers playback from this local player to another device.
    /// Uses the native Spotify Connect protocol via SpClient for seamless handoff.
    /// - Parameter deviceId: The target device ID to transfer playback to
    static func transferPlayback(to deviceId: String) throws {
        Task {
            try await client.transferPlayback(toDeviceId: deviceId)
        }
    }

    /// Adds an item to the queue via Spirc.
    /// - Parameter uri: The Spotify URI to add to the queue (track, episode, etc.)
    static func addToQueue(uri: String) throws {
        Task {
            try await client.addToQueue(uri: uri)
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
        client.setBitrate(bitrate)
    }

    /// Gets the current bitrate setting.
    static var bitrate: Bitrate {
        .normal // TODO: Get from LibrespotClient
    }

    /// Sets gapless playback. Takes effect on next player initialization.
    static func setGapless(_ enabled: Bool) {
        client.setGapless(enabled)
    }

    /// Gets the current gapless playback setting.
    static var gapless: Bool {
        true // TODO: Get from LibrespotClient
    }
}
