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
        let result = await Task.detached {
            accessToken.withCString { tokenPtr in
                spotifly_init_player(tokenPtr)
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.initializationFailed
        }
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

    /// Returns whether the player is currently playing.
    static var isPlaying: Bool {
        spotifly_is_playing() == 1
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

    /// Jumps to a specific track in the queue by index and starts playing.
    static func jumpToIndex(_ index: Int) throws {
        let result = spotifly_jump_to_index(index)
        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Returns the number of tracks in the queue.
    static var queueLength: Int {
        spotifly_get_queue_length()
    }

    /// Returns the current track index in the queue (0-based).
    static var currentIndex: Int {
        spotifly_get_current_index()
    }

    /// Returns the track name at the given index in the queue.
    static func queueTrackName(at index: Int) -> String? {
        guard let cStr = spotifly_get_queue_track_name(index) else {
            return nil
        }
        defer { spotifly_free_string(cStr) }
        return String(cString: cStr)
    }

    /// Returns the artist name at the given index in the queue.
    static func queueArtistName(at index: Int) -> String? {
        guard let cStr = spotifly_get_queue_artist_name(index) else {
            return nil
        }
        defer { spotifly_free_string(cStr) }
        return String(cString: cStr)
    }

    /// Returns the album art URL at the given index in the queue.
    static func queueAlbumArtUrl(at index: Int) -> String? {
        guard let cStr = spotifly_get_queue_album_art_url(index) else {
            return nil
        }
        defer { spotifly_free_string(cStr) }
        return String(cString: cStr)
    }

    /// Returns the URI at the given index in the queue.
    static func queueUri(at index: Int) -> String? {
        guard let cStr = spotifly_get_queue_uri(index) else {
            return nil
        }
        defer { spotifly_free_string(cStr) }
        return String(cString: cStr)
    }

    /// Returns the track duration in milliseconds at the given index.
    static func queueDurationMs(at index: Int) -> UInt32 {
        spotifly_get_queue_duration_ms(index)
    }

    /// Fetches all queue items.
    static func getAllQueueItems() throws -> [QueueItem] {
        guard let cStr = spotifly_get_all_queue_items() else {
            throw SpotifyPlayerError.queueFetchFailed
        }
        defer { spotifly_free_string(cStr) }

        let jsonString = String(cString: cStr)
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw SpotifyPlayerError.queueFetchFailed
        }

        // Parse JSON manually since we're getting snake_case from Rust
        guard let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            throw SpotifyPlayerError.queueFetchFailed
        }

        return jsonArray.compactMap { item in
            guard let uri = item["uri"] as? String,
                  let trackName = item["track_name"] as? String,
                  let artistName = item["artist_name"] as? String,
                  let albumArtURL = item["album_art_url"] as? String,
                  let durationMs = item["duration_ms"] as? UInt32
            else {
                return nil
            }

            // Optional fields for navigation
            let albumId = item["album_id"] as? String
            let artistId = item["artist_id"] as? String
            let externalUrl = item["external_url"] as? String

            return QueueItem(
                id: uri,
                uri: uri,
                trackName: trackName,
                artistName: artistName,
                albumArtURL: albumArtURL,
                durationMs: durationMs,
                albumId: albumId,
                artistId: artistId,
                externalUrl: externalUrl,
            )
        }
    }

    /// Adds a track to the end of the current queue without clearing it.
    @SpotifyAuthActor
    static func addToQueue(trackUri: String) async throws {
        let result = await Task.detached {
            trackUri.withCString { ptr in
                spotifly_add_to_queue(ptr)
            }
        }.value

        guard result == 0 else {
            throw SpotifyPlayerError.playbackFailed
        }
    }

    /// Adds a track to play next (after the currently playing track).
    @SpotifyAuthActor
    static func addNextToQueue(trackUri: String) async throws {
        let result = await Task.detached {
            trackUri.withCString { ptr in
                spotifly_add_next_to_queue(ptr)
            }
        }.value

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
}
