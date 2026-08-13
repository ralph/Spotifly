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
            return "\(hours.formatted()) hr \(minutes.formatted()) min"
        } else {
            return "\(minutes.formatted()) min"
        }
    }
}

// MARK: - Unified Track Type

/// Unified track type from Spotify API.
/// Used for all track sources: search, saved, album, playlist, playback.
struct APITrack: Identifiable {
    let id: String
    let addedAt: String?
    let albumId: String?
    let albumName: String?
    let artistId: String?
    let artistName: String
    let durationMs: Int
    let externalUrl: String?
    let images: ImageSet
    let name: String
    let trackNumber: Int?
    let uri: String
}

// MARK: - Album Types

/// Album metadata from Spotify API
struct APIAlbum: Identifiable, DurationFormattable {
    let id: String
    let albumType: String?
    let artistId: String?
    let artistName: String
    let externalUrl: String?
    let images: ImageSet
    let name: String
    let releaseDate: String
    let totalDurationMs: Int?
    let trackCount: Int
    let uri: String
}

// MARK: - Artist Types

/// Artist metadata from Spotify API
struct APIArtist: Identifiable {
    let id: String
    let genres: [String]
    let images: ImageSet
    let name: String
    let uri: String
    let externalUrl: String?
}

// MARK: - Playlist Types

/// Playlist metadata from Spotify API
struct APIPlaylist: Identifiable, DurationFormattable {
    let id: String
    let description: String?
    let images: ImageSet
    let isPublic: Bool?
    var name: String
    let ownerId: String
    let ownerName: String
    let totalDurationMs: Int?
    var trackCount: Int
    let uri: String
    let externalUrl: String?
}

// MARK: - Search Types

/// Search results wrapper (uses unified Entity types)
struct SearchResults: Encodable {
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let tracks: [Track]
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

extension [ImageCodable] {
    /// Convert API image response to an ImageSet with all available sizes.
    var toImageSet: ImageSet {
        let variants = compactMap { img -> ImageVariant? in
            guard let url = URL(string: img.url) else { return nil }
            let size = img.width ?? img.height ?? 0
            return ImageVariant(url: url, size: size)
        }
        return ImageSet(variants: variants.sorted { $0.size > $1.size })
    }

    /// Preferred single URL for contexts that only need one (e.g. UserProfile).
    var preferredURL: String? {
        let medium = first(where: { ($0.width ?? Int.max) <= 400 && ($0.width ?? 0) >= 100 })
        return (medium ?? first)?.url
    }
}

struct ExternalUrlsCodable: Decodable {
    let spotify: String?
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

// MARK: Artist Codable

struct ArtistCodable: Decodable {
    let id: String?
    let name: String
    let uri: String?
    let genres: [String]?
    let images: [ImageCodable]?
    let externalUrls: ExternalUrlsCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, genres, images
        case externalUrls = "external_urls"
    }
}

extension ArtistCodable {
    func toAPIArtist() -> APIArtist? {
        guard let id, let uri else { return nil }
        return APIArtist(
            id: id,
            genres: genres ?? [],
            images: images?.toImageSet ?? ImageSet.empty,
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

// MARK: Track Codable

/// # Identity
///
/// The id Spotify returns *is* the identity — this type takes it as given and never rewrites
/// it. Every request here sends `market=from_token`, so what comes back is the recording
/// playable on this account, and `AGENTS.md` ("Track identity is the market id") explains why
/// that is the only id the app can consistently hold.
///
/// The short version: pathfinder, which now answers search, returns the market recording and
/// carries no `linked_from` to trade it back for the original. Reconstructing originals here
/// would leave the two halves of the app naming the same track differently.
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

    func toAPITrack(addedAt: String? = nil, albumId: String? = nil, albumName: String? = nil, images: ImageSet? = nil) -> APITrack {
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
            images: images ?? album?.images?.toImageSet ?? ImageSet.empty,
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
    let tracks: PlaylistItemsCodable?
    let externalUrls: ExternalUrlsCodable?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, description, images, owner, tracks
        case `public`
        case externalUrls = "external_urls"
    }

    struct PlaylistItemsCodable: Decodable {
        let total: Int?
        let items: [PlaylistItemWrapperCodable]?
    }

    struct PlaylistItemWrapperCodable: Decodable {
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
            images: images?.toImageSet ?? ImageSet.empty,
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
    let disableVolume: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isPrivateSession = "is_private_session"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
        case disableVolume = "disable_volume"
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
            // Absent means nothing was declared, which is not a declaration that volume is
            // refused — so the slider stays live and the command decides, as before.
            disableVolume: disableVolume ?? false,
        )
    }
}

// MARK: - Response Codables

/// Playlist items
struct PlaylistItemsCodable: Decodable {
    let items: [PlaylistItemWrapperCodable]
    let next: String?

    struct PlaylistItemWrapperCodable: Decodable {
        let addedAt: String?
        let track: TrackCodable?

        enum CodingKeys: String, CodingKey {
            case addedAt = "added_at"
            case track
        }
    }
}

// MARK: - Errors

/// Errors from the four playlist-management calls still on `api.spotify.com`.
///
/// Three cases went with what they described: `forbidden` was `/me` refusing an account the
/// dashboard app had not whitelisted, `noActiveDevice` was a `/me/player/*` command finding
/// nothing to send itself to, and `networkError` was never thrown at all.
enum SpotifyAPIError: Error, LocalizedError {
    case apiError(String)
    case invalidResponse
    case invalidURI
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
        case .notFound:
            "Track not found"
        case .unauthorized:
            "Unauthorized - please log in again"
        }
    }
}
