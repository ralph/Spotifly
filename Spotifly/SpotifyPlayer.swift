//
//  SpotifyPlayer.swift
//  Spotifly
//
//  Swift wrapper for the Rust librespot playback functionality
//

import Foundation
import SpotiflyRust

/// Errors that can occur during playback
enum SpotifyPlayerError: Error, LocalizedError, Sendable {
    case initializationFailed
    case playbackFailed
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .initializationFailed:
            "Failed to initialize player"
        case .playbackFailed:
            "Failed to play track"
        case .notInitialized:
            "Player not initialized"
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

    /// Cleans up player resources.
    static func cleanup() {
        spotifly_cleanup_player()
    }
}
