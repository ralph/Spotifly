//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the Rust librespot playback functionality
//

import Foundation
import SpotiflyRust
import Combine

/// Queue item metadata (nonisolated for C callback compatibility)
struct QueueItem: Sendable, Identifiable {
    nonisolated let id: String // uri
    nonisolated let uri: String
    nonisolated let trackName: String
    nonisolated let artistName: String
    nonisolated let albumArtURL: String
    nonisolated let durationMs: UInt32
    nonisolated let albumId: String?
    nonisolated let artistId: String?
    nonisolated let externalUrl: String?

    nonisolated var durationFormatted: String {
        let totalSeconds = Int(durationMs / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Memberwise initializer
    nonisolated init(
        id: String,
        uri: String,
        trackName: String,
        artistName: String,
        albumArtURL: String,
        durationMs: UInt32,
        albumId: String?,
        artistId: String?,
        externalUrl: String?
    ) {
        self.id = id
        self.uri = uri
        self.trackName = trackName
        self.artistName = artistName
        self.albumArtURL = albumArtURL
        self.durationMs = durationMs
        self.albumId = albumId
        self.artistId = artistId
        self.externalUrl = externalUrl
    }

    /// Create from Spotify API APITrack
    @MainActor init(from track: APITrack) {
        id = track.uri
        uri = track.uri
        trackName = track.name
        artistName = track.artistName
        albumArtURL = track.imageURL?.absoluteString ?? ""
        durationMs = UInt32(track.durationMs)
        albumId = track.albumId
        artistId = track.artistId
        externalUrl = track.externalUrl ?? "https://open.spotify.com/track/\(track.id)"
    }
}

/// Queue state containing current, next, and previous tracks (nonisolated for C callback compatibility)
struct QueueState: Sendable {
    nonisolated let currentTrack: QueueItem?
    nonisolated let nextTracks: [QueueItem]
    nonisolated let previousTracks: [QueueItem]
}

/// Global subject for queue updates (nonisolated for C callback access)
private nonisolated(unsafe) let queueSubject = CurrentValueSubject<QueueState?, Never>(nil)

/// Registers the queue callback with Rust (must be called from nonisolated context)
private nonisolated func registerQueueCallback() {
    spotifly_register_queue_callback { jsonPtr in
        handleQueueCallback(jsonPtr)
    }
}

/// Parses a queue item from a JSON dictionary (manual parsing to avoid Decodable actor isolation issues)
private nonisolated func parseQueueItem(from dict: [String: Any]) -> QueueItem? {
    guard let uri = dict["uri"] as? String else { return nil }
    return QueueItem(
        id: uri,
        uri: uri,
        trackName: dict["name"] as? String ?? "",
        artistName: dict["artist"] as? String ?? "",
        albumArtURL: dict["image_url"] as? String ?? "",
        durationMs: (dict["duration_ms"] as? NSNumber)?.uint32Value ?? 0,
        albumId: nil,
        artistId: nil,
        externalUrl: nil
    )
}

/// C callback for queue updates from Rust
/// Uses manual JSON parsing to avoid Decodable actor isolation issues
private nonisolated func handleQueueCallback(_ jsonPtr: UnsafePointer<CChar>?) {
    #if DEBUG
        print("[SpotifyPlayer] handleQueueCallback called")
    #endif

    guard let jsonPtr = jsonPtr else {
        #if DEBUG
            print("[SpotifyPlayer] handleQueueCallback: jsonPtr is nil")
        #endif
        return
    }

    let jsonString = String(cString: jsonPtr)
    #if DEBUG
        print("[SpotifyPlayer] handleQueueCallback received JSON (\(jsonString.count) chars)")
    #endif

    guard let data = jsonString.data(using: .utf8) else {
        #if DEBUG
            print("[SpotifyPlayer] handleQueueCallback: failed to convert JSON to data")
        #endif
        return
    }

    do {
        // Use JSONSerialization instead of Decodable to avoid actor isolation issues
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
                print("[SpotifyPlayer] handleQueueCallback: JSON is not a dictionary")
            #endif
            return
        }

        // Parse current track
        let currentTrack: QueueItem?
        if let trackDict = json["track"] as? [String: Any] {
            currentTrack = parseQueueItem(from: trackDict)
        } else {
            currentTrack = nil
        }

        // Parse next tracks
        let nextTracks: [QueueItem]
        if let nextArray = json["next_tracks"] as? [[String: Any]] {
            nextTracks = nextArray.compactMap { parseQueueItem(from: $0) }
        } else {
            nextTracks = []
        }

        // Parse previous tracks
        let prevTracks: [QueueItem]
        if let prevArray = json["prev_tracks"] as? [[String: Any]] {
            prevTracks = prevArray.compactMap { parseQueueItem(from: $0) }
        } else {
            prevTracks = []
        }

        let state = QueueState(
            currentTrack: currentTrack,
            nextTracks: nextTracks,
            previousTracks: prevTracks
        )

        #if DEBUG
            let trackName = state.currentTrack?.trackName ?? "none"
            let nextCount = state.nextTracks.count
            let prevCount = state.previousTracks.count
            print("[SpotifyPlayer] handleQueueCallback: current='\(trackName)', next=\(nextCount), prev=\(prevCount)")
        #endif

        queueSubject.send(state)
    } catch {
        print("[SpotifyPlayer] Failed to parse queue JSON: \(error)")
        #if DEBUG
            let preview = String(jsonString.prefix(500))
            print("[SpotifyPlayer] JSON preview: \(preview)")
        #endif
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

/// Swift wrapper for the Rust librespot playback functionality
enum SpotifyPlayer {
    /// Initializes the player with the given access token.
    /// Must be called before any playback operations.
    @SpotifyAuthActor
    static func initialize(accessToken: String) async throws {
        // Register queue callback (via nonisolated helper to avoid actor isolation issues)
        registerQueueCallback()

        // Sync playback settings from UserDefaults before initializing
        syncSettingsFromUserDefaults()

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

    /// Syncs playback settings from UserDefaults to the Rust player
    private nonisolated static func syncSettingsFromUserDefaults() {
        let bitrateRawValue = UserDefaults.standard.object(forKey: "streamingBitrate") as? Int ?? 1
        let gaplessEnabled = UserDefaults.standard.object(forKey: "gaplessPlayback") as? Bool ?? true

        // Call FFI directly to avoid actor isolation issues
        spotifly_set_bitrate(UInt8(min(max(bitrateRawValue, 0), 2)))
        spotifly_set_gapless(gaplessEnabled)
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
    static func pause() {
        spotifly_pause()
    }

    /// Resumes playback.
    static func resume() {
        spotifly_resume()
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
    static func next() throws {
        let result = spotifly_next()
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Skips to the previous track in the queue.
    static func previous() throws {
        let result = spotifly_previous()
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Seeks to the given position in milliseconds.
    static func seek(positionMs: UInt32) throws {
        let result = spotifly_seek(positionMs)
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Sets the playback volume (0.0 - 1.0).
    static func setVolume(_ volume: Double) {
        let volumeU16 = UInt16(max(0, min(1, volume)) * 65535.0)
        spotifly_set_volume(volumeU16)
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
