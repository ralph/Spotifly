//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the Rust librespot playback functionality
//

import Foundation
import SpotiflyRust

/// Queue item metadata
struct QueueItem: Sendable, Identifiable {
    let id: String // uri
    let uri: String
    let trackName: String
    let artistName: String
    let albumArtURL: String
    let durationMs: UInt32
    let albumId: String?
    let artistId: String?
    let externalUrl: String?

    var durationFormatted: String {
        let totalSeconds = Int(durationMs / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Memberwise initializer
    init(
        id: String,
        uri: String,
        trackName: String,
        artistName: String,
        albumArtURL: String,
        durationMs: UInt32,
        albumId: String?,
        artistId: String?,
        externalUrl: String?,
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
    init(from track: APITrack) {
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
                spotifly_play_track(ptr)
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

    /// Gets radio track URIs for a seed track using librespot's internal API.
    /// - Parameter trackUri: The Spotify track URI to use as seed
    /// - Returns: Array of track URIs for the radio playlist
    static func getRadioTracks(trackUri: String) throws -> [String] {
        let cStr: UnsafeMutablePointer<CChar>? = trackUri.withCString { ptr in
            spotifly_get_radio_tracks(ptr)
        }

        guard let cStr else {
            throw SpotifyPlayerError.playbackFailed
        }
        defer { spotifly_free_string(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8),
              let trackUris = try? JSONDecoder().decode([String].self, from: jsonData)
        else {
            throw SpotifyPlayerError.playbackFailed
        }

        return trackUris
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
