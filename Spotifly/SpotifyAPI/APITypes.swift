//
//  APITypes.swift
//  Spotifly
//
//  Data types for Spotify Web API responses.
//

import Foundation

// MARK: - Duration Formatting Protocol

/// Protocol for types that have a total duration in milliseconds
protocol DurationFormattable {
    var totalDurationMs: Int? { get }
}

extension DurationFormattable {
    /// Formats the total duration as "X hr Y min" or "Y min"
    var formattedDuration: String? {
        guard let totalDurationMs else { return nil }
        let totalSeconds = totalDurationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
    }
}

// MARK: - Unified Track Type

/// Unified track type from Spotify API.
/// Used for all track sources: search, saved, album, playlist, playback.
struct APITrack: Sendable, Identifiable {
    let id: String
    let addedAt: String?
    let albumId: String?
    let albumName: String?
    let artistId: String?
    let artistName: String
    let durationMs: Int
    let externalUrl: String?
    let imageURL: URL?
    let name: String
    let trackNumber: Int?
    let uri: String
}

// MARK: - Album Types

/// Album metadata from Spotify API
struct APIAlbum: Sendable, Identifiable, DurationFormattable {
    let id: String
    let albumType: String?
    let artistId: String?
    let artistName: String
    let externalUrl: String?
    let imageURL: URL?
    let name: String
    let releaseDate: String
    let totalDurationMs: Int?
    let trackCount: Int
    let uri: String
}

/// Response wrapper for albums endpoint
struct AlbumsResponse: Sendable {
    let albums: [APIAlbum]
    let hasMore: Bool
    let nextOffset: Int?
    let total: Int
}

/// Response wrapper for new releases endpoint
struct NewReleasesResponse: Sendable {
    let albums: [APIAlbum]
    let hasMore: Bool
    let nextOffset: Int?
    let total: Int
}

// MARK: - Artist Types

/// Artist metadata from Spotify API
struct APIArtist: Sendable, Identifiable {
    let id: String
    let followers: Int
    let genres: [String]
    let imageURL: URL?
    let name: String
    let uri: String
}

/// Response wrapper for artists endpoint
struct ArtistsResponse: Sendable {
    let artists: [APIArtist]
    let hasMore: Bool
    let nextCursor: String?
    let total: Int
}

/// Response wrapper for user's top artists endpoint
struct TopArtistsResponse: Sendable {
    let artists: [APIArtist]
    let hasMore: Bool
    let nextOffset: Int?
    let total: Int
}

// MARK: - Playlist Types

/// Playlist metadata from Spotify API
struct APIPlaylist: Sendable, Identifiable, DurationFormattable {
    let id: String
    let description: String?
    let imageURL: URL?
    let isPublic: Bool?
    var name: String
    let ownerId: String
    let ownerName: String
    let totalDurationMs: Int?
    var trackCount: Int
    let uri: String
}

/// Response wrapper for playlists endpoint
struct PlaylistsResponse: Sendable {
    let hasMore: Bool
    let nextOffset: Int?
    let playlists: [APIPlaylist]
    let total: Int
}

// MARK: - Saved Tracks

/// Response wrapper for saved tracks endpoint
struct SavedTracksResponse: Sendable {
    let hasMore: Bool
    let nextOffset: Int?
    let total: Int
    let tracks: [APITrack]
}

// MARK: - Search Types

/// Search result type
enum SearchType: String, Sendable {
    case album
    case artist
    case playlist
    case track
}

/// Search results wrapper (uses unified Entity types)
struct SearchResults: Sendable {
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let tracks: [Track]
}

// MARK: - Recently Played

/// Recently played context
struct PlaybackContext: Sendable {
    let type: String // "album", "playlist", "artist"
    let uri: String
}

/// Recently played item
struct RecentlyPlayedItem: Sendable, Identifiable {
    let id: String // Use played_at as ID since tracks can be played multiple times
    let context: PlaybackContext?
    let playedAt: String
    let track: APITrack
}

/// Recently played response wrapper
struct RecentlyPlayedResponse: Sendable {
    let items: [RecentlyPlayedItem]
}

// MARK: - Playback & Connect Types

/// Spotify Connect device
struct SpotifyDevice: Sendable, Identifiable {
    let id: String
    let isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let name: String
    let type: String // "Computer", "Smartphone", "Speaker", etc.
    let volumePercent: Int?
}

/// Devices response wrapper
struct DevicesResponse: Sendable {
    let devices: [SpotifyDevice]
}

/// Current playback state from Spotify
struct PlaybackState: Sendable {
    let currentTrack: APITrack?
    let device: SpotifyDevice?
    let isPlaying: Bool
    let progressMs: Int
    let repeatState: String
    let shuffleState: Bool
}

/// Queue response from Spotify
struct QueueResponse: Sendable {
    let currentlyPlaying: APITrack?
    let queue: [APITrack]
}

// MARK: - User Top Items

/// Time range for top items (artists/tracks)
enum TopItemsTimeRange: String, Sendable {
    case longTerm = "long_term" // ~1 year
    case mediumTerm = "medium_term" // ~6 months (default)
    case shortTerm = "short_term" // ~4 weeks
}

// MARK: - Legacy Track Types (to be removed after migration)

/// Track metadata from single track lookup
struct TrackMetadata: Sendable {
    let id: String
    let albumImageURL: URL?
    let albumName: String
    let artistName: String
    let durationMs: Int
    let name: String
    let previewURL: URL?

    var durationFormatted: String {
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Errors

/// Errors from Spotify API
enum SpotifyAPIError: Error, LocalizedError {
    case apiError(String)
    case invalidResponse
    case invalidURI
    case networkError(Error)
    case notFound
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .apiError(message):
            "Spotify API error: \(message)"
        case .invalidResponse:
            "Invalid response from Spotify"
        case .invalidURI:
            "Invalid Spotify URI format"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case .notFound:
            "Track not found"
        case .unauthorized:
            "Unauthorized - please log in again"
        }
    }
}
