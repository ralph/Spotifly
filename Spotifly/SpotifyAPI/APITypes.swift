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
    let externalUrl: String?
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

/// Response wrapper for user's top tracks endpoint
struct TopTracksResponse: Sendable {
    let tracks: [APITrack]
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
    let externalUrl: String?
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
struct SearchResults: Sendable, Encodable {
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

/// Devices response wrapper
struct DevicesResponse: Sendable {
    let devices: [Device]
}

// MARK: - User Top Items

/// Time range for top items (artists/tracks)
enum TopItemsTimeRange: String, Sendable {
    case longTerm = "long_term" // ~1 year
    case mediumTerm = "medium_term" // ~6 months (default)
    case shortTerm = "short_term" // ~4 weeks
}

// MARK: - Codable Response Types (Internal)

// These types are used only for JSON decoding from Spotify API responses.
// They map directly to the JSON structure, then convert to the public API types.

// MARK: Shared Primitives

struct SpotifyErrorResponse: Decodable {
    let error: SpotifyErrorBody
    struct SpotifyErrorBody: Decodable {
        let message: String
        let status: Int
    }
}

struct ImageCodable: Decodable {
    let url: String
    let height: Int?
    let width: Int?
}

struct ExternalUrlsCodable: Decodable {
    let spotify: String?
}

struct FollowersCodable: Decodable {
    let total: Int?
}

struct ContextCodable: Decodable {
    let type: String
    let uri: String
}

struct OwnerCodable: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct CursorsCodable: Decodable {
    let after: String?
}

// MARK: Artist Codable

struct ArtistCodable: Decodable {
    let id: String?
    let name: String
    let uri: String?
    let genres: [String]?
    let followers: FollowersCodable?
    let images: [ImageCodable]?
    let externalUrls: ExternalUrlsCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, genres, followers, images
        case externalUrls = "external_urls"
    }
}

extension ArtistCodable {
    func toAPIArtist() -> APIArtist? {
        guard let id, let uri else { return nil }
        return APIArtist(
            id: id,
            followers: followers?.total ?? 0,
            genres: genres ?? [],
            imageURL: (images?.first?.url).flatMap { URL(string: $0) },
            name: name,
            uri: uri,
            externalUrl: externalUrls?.spotify,
        )
    }
}

// MARK: Album Codable (simplified for nested use)

struct AlbumSimpleCodable: Decodable {
    let id: String?
    let name: String
    let images: [ImageCodable]?
}

// MARK: Album Codable (full)

struct AlbumCodable: Decodable {
    let id: String
    let name: String
    let uri: String
    let albumType: String?
    let totalTracks: Int?
    let releaseDate: String?
    let artists: [ArtistCodable]?
    let images: [ImageCodable]?
    let tracks: TracksPagingCodable?
    let externalUrls: ExternalUrlsCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, images, tracks
        case albumType = "album_type"
        case totalTracks = "total_tracks"
        case releaseDate = "release_date"
        case externalUrls = "external_urls"
    }

    struct TracksPagingCodable: Decodable {
        let items: [TrackItemCodable]?
        struct TrackItemCodable: Decodable {
            let durationMs: Int?
            enum CodingKeys: String, CodingKey {
                case durationMs = "duration_ms"
            }
        }
    }

    func toAPIAlbum() -> APIAlbum {
        let artist = artists?.first
        let totalDurationMs = tracks?.items?.compactMap(\.durationMs).reduce(0, +)
        return APIAlbum(
            id: id,
            albumType: albumType,
            artistId: artist?.id,
            artistName: artist?.name ?? "Unknown",
            externalUrl: externalUrls?.spotify,
            imageURL: (images?.first?.url).flatMap { URL(string: $0) },
            name: name,
            releaseDate: releaseDate ?? "",
            totalDurationMs: totalDurationMs,
            trackCount: totalTracks ?? 0,
            uri: uri,
        )
    }
}

// MARK: Track Codable

struct TrackCodable: Decodable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int
    let trackNumber: Int?
    let artists: [ArtistCodable]?
    let album: AlbumSimpleCodable?
    let externalUrls: ExternalUrlsCodable?
    let previewUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, album
        case durationMs = "duration_ms"
        case trackNumber = "track_number"
        case externalUrls = "external_urls"
        case previewUrl = "preview_url"
    }

    func toAPITrack(addedAt: String? = nil, albumId: String? = nil, albumName: String? = nil, imageURL: URL? = nil) -> APITrack {
        let artist = artists?.first
        return APITrack(
            id: id,
            addedAt: addedAt,
            albumId: albumId ?? album?.id,
            albumName: albumName ?? album?.name,
            artistId: artist?.id,
            artistName: artist?.name ?? "Unknown",
            durationMs: durationMs,
            externalUrl: externalUrls?.spotify,
            imageURL: imageURL ?? (album?.images?.first?.url).flatMap { URL(string: $0) },
            name: name,
            trackNumber: trackNumber,
            uri: uri,
        )
    }
}

// MARK: Playlist Codable

struct PlaylistCodable: Decodable {
    let id: String
    let name: String
    let uri: String
    let description: String?
    let images: [ImageCodable]?
    let owner: OwnerCodable
    let `public`: Bool?
    let tracks: PlaylistTracksCodable?
    let externalUrls: ExternalUrlsCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, description, images, owner, tracks
        case `public`
        case externalUrls = "external_urls"
    }

    struct PlaylistTracksCodable: Decodable {
        let total: Int?
        let items: [PlaylistTrackItemCodable]?
    }

    struct PlaylistTrackItemCodable: Decodable {
        let track: TrackDurationCodable?
        struct TrackDurationCodable: Decodable {
            let durationMs: Int?
            enum CodingKeys: String, CodingKey {
                case durationMs = "duration_ms"
            }
        }
    }

    func toAPIPlaylist() -> APIPlaylist {
        let durations = tracks?.items?.compactMap { $0.track?.durationMs } ?? []
        let totalDurationMs = durations.isEmpty ? nil : durations.reduce(0, +)
        return APIPlaylist(
            id: id,
            description: description,
            imageURL: (images?.first?.url).flatMap { URL(string: $0) },
            isPublic: `public`,
            name: name,
            ownerId: owner.id,
            ownerName: owner.displayName ?? owner.id,
            totalDurationMs: totalDurationMs,
            trackCount: tracks?.total ?? 0,
            uri: uri,
            externalUrl: externalUrls?.spotify,
        )
    }
}

// MARK: Device Codable

struct DeviceCodable: Decodable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool?
    let isPrivateSession: Bool?
    let isRestricted: Bool?
    let volumePercent: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isPrivateSession = "is_private_session"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
    }

    func toDevice() -> Device? {
        guard let id else { return nil }
        return Device(
            id: id,
            name: name,
            type: type,
            isActive: isActive ?? false,
            isPrivateSession: isPrivateSession ?? false,
            isRestricted: isRestricted ?? false,
            volumePercent: volumePercent,
        )
    }
}

// MARK: - Response Codables

/// User profile
struct UserProfileCodable: Decodable {
    let id: String
    let displayName: String?
    let email: String?
    let images: [ImageCodable]?
    let externalUrls: ExternalUrlsCodable?
    let followers: FollowersCodable?
    let product: String?
    let country: String?
    let uri: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case email
        case images
        case externalUrls = "external_urls"
        case followers
        case product
        case country
        case uri
    }
}

/// Saved tracks
struct SavedTracksCodable: Decodable {
    let items: [SavedTrackItemCodable]
    let total: Int
    let next: String?

    struct SavedTrackItemCodable: Decodable {
        let addedAt: String?
        let track: TrackCodable

        enum CodingKeys: String, CodingKey {
            case addedAt = "added_at"
            case track
        }
    }
}

// Check saved tracks (returns array of bools)
// Note: This is just [Bool], decoded directly

/// Album tracks
struct AlbumTracksCodable: Decodable {
    let items: [AlbumTrackItemCodable]

    struct AlbumTrackItemCodable: Decodable {
        let id: String
        let name: String
        let uri: String
        let durationMs: Int
        let trackNumber: Int?
        let artists: [ArtistCodable]?
        let externalUrls: ExternalUrlsCodable?

        enum CodingKeys: String, CodingKey {
            case id, name, uri, artists
            case durationMs = "duration_ms"
            case trackNumber = "track_number"
            case externalUrls = "external_urls"
        }

        func toAPITrack(albumId: String, albumName: String?, imageURL: URL?) -> APITrack {
            let artist = artists?.first
            return APITrack(
                id: id,
                addedAt: nil,
                albumId: albumId,
                albumName: albumName,
                artistId: artist?.id,
                artistName: artist?.name ?? "Unknown",
                durationMs: durationMs,
                externalUrl: externalUrls?.spotify,
                imageURL: imageURL,
                name: name,
                trackNumber: trackNumber,
                uri: uri,
            )
        }
    }
}

/// Playlist tracks
struct PlaylistTracksCodable: Decodable {
    let items: [PlaylistTrackItemCodable]

    struct PlaylistTrackItemCodable: Decodable {
        let addedAt: String?
        let track: TrackCodable?

        enum CodingKeys: String, CodingKey {
            case addedAt = "added_at"
            case track
        }
    }
}

/// Artist top tracks
struct ArtistTopTracksCodable: Decodable {
    let tracks: [TrackCodable]
}

/// Multiple tracks (batch fetch)
struct MultipleTracksCodable: Decodable {
    let tracks: [TrackCodable?] // Can contain nulls for not-found tracks
}

/// User albums
struct UserAlbumsCodable: Decodable {
    let items: [UserAlbumItemCodable]
    let total: Int
    let next: String?

    struct UserAlbumItemCodable: Decodable {
        let album: AlbumCodable
    }
}

/// Artist albums
struct ArtistAlbumsCodable: Decodable {
    let items: [AlbumCodable]
}

/// New releases
struct NewReleasesCodable: Decodable {
    let albums: AlbumsPagingCodable

    struct AlbumsPagingCodable: Decodable {
        let items: [AlbumCodable]
        let total: Int
    }
}

/// User artists (followed)
struct UserArtistsCodable: Decodable {
    let artists: ArtistsPagingCodable

    struct ArtistsPagingCodable: Decodable {
        let items: [ArtistCodable]
        let total: Int
        let cursors: CursorsCodable?
    }
}

/// Top artists
struct TopArtistsCodable: Decodable {
    let items: [ArtistCodable]
    let total: Int
    let next: String?
}

/// Top tracks
struct TopTracksCodable: Decodable {
    let items: [TrackCodable]
    let total: Int
    let next: String?
}

/// User playlists
struct UserPlaylistsCodable: Decodable {
    let items: [PlaylistCodable]
    let total: Int
    let next: String?
}

/// Devices
struct DevicesCodable: Decodable {
    let devices: [DeviceCodable]
}

/// Recently played
struct RecentlyPlayedCodable: Decodable {
    let items: [RecentlyPlayedItemCodable]

    struct RecentlyPlayedItemCodable: Decodable {
        let track: TrackCodable
        let playedAt: String
        let context: ContextCodable?

        enum CodingKeys: String, CodingKey {
            case track
            case playedAt = "played_at"
            case context
        }
    }

    func toRecentlyPlayedResponse() -> RecentlyPlayedResponse {
        let items = items.map { item in
            RecentlyPlayedItem(
                id: item.playedAt,
                context: item.context.map { PlaybackContext(type: $0.type, uri: $0.uri) },
                playedAt: item.playedAt,
                track: item.track.toAPITrack(),
            )
        }
        return RecentlyPlayedResponse(items: items)
    }
}

/// Search results
struct SearchResultsCodable: Decodable {
    let tracks: TracksPagingCodable?
    let albums: AlbumsPagingCodable?
    let artists: ArtistsPagingCodable?
    let playlists: PlaylistsPagingCodable?

    struct TracksPagingCodable: Decodable {
        let items: [TrackCodable]?
    }

    struct AlbumsPagingCodable: Decodable {
        let items: [AlbumCodable]?
    }

    struct ArtistsPagingCodable: Decodable {
        let items: [ArtistCodable]?
    }

    struct PlaylistsPagingCodable: Decodable {
        /// Items can be null for deleted/unavailable playlists
        let items: [PlaylistCodable?]?
    }
}

// MARK: - Errors

/// Errors from Spotify API
enum SpotifyAPIError: Error, LocalizedError {
    case apiError(String)
    case forbidden
    case invalidResponse
    case invalidURI
    case networkError(Error)
    case notFound
    case unauthorized

    var errorDescription: String? {
        switch self {
        case let .apiError(message):
            "Spotify API error: \(message)"
        case .forbidden:
            "Forbidden - access denied"
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
