//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify Web API client for fetching track metadata
//

import Foundation
import os.log

private let apiLogger = Logger(subsystem: "com.spotifly.app", category: "SpotifyAPI")

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

// MARK: - Track Metadata

/// Track metadata from Spotify
struct TrackMetadata: Sendable {
    let id: String
    let name: String
    let artistName: String
    let albumName: String
    let albumImageURL: URL?
    let durationMs: Int
    let previewURL: URL?

    var durationFormatted: String {
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Simplified playlist metadata from Spotify
struct PlaylistSimplified: Sendable, Identifiable, DurationFormattable {
    let id: String
    var name: String
    let description: String?
    let imageURL: URL?
    var trackCount: Int
    let uri: String
    let isPublic: Bool
    let ownerId: String
    let ownerName: String
    let totalDurationMs: Int?
}

/// Response wrapper for playlists endpoint
struct PlaylistsResponse: Sendable {
    let playlists: [PlaylistSimplified]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
}

/// Simplified album metadata from Spotify
struct AlbumSimplified: Sendable, Identifiable, DurationFormattable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
    let trackCount: Int
    let uri: String
    let releaseDate: String
    let albumType: String
    let totalDurationMs: Int?
}

/// Response wrapper for albums endpoint
struct AlbumsResponse: Sendable {
    let albums: [AlbumSimplified]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
}

/// Simplified artist metadata from Spotify
struct ArtistSimplified: Sendable, Identifiable {
    let id: String
    let name: String
    let imageURL: URL?
    let uri: String
    let genres: [String]
    let followers: Int
}

/// Response wrapper for artists endpoint
struct ArtistsResponse: Sendable {
    let artists: [ArtistSimplified]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
}

/// Saved track (favorite) metadata from Spotify
struct SavedTrack: Sendable, Identifiable {
    let id: String
    let name: String
    let artistName: String
    let albumName: String
    let imageURL: URL?
    let durationMs: Int
    let uri: String
    let addedAt: String
    let albumId: String?
    let artistId: String?
    let externalUrl: String?
}

/// Response wrapper for saved tracks endpoint
struct SavedTracksResponse: Sendable {
    let tracks: [SavedTrack]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
}

/// Album track (from album tracks endpoint)
struct AlbumTrack: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let durationMs: Int
    let trackNumber: Int
    let artistId: String?
    let externalUrl: String?
}

/// Playlist track (from playlist tracks endpoint)
struct PlaylistTrack: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let albumName: String
    let imageURL: URL?
    let durationMs: Int
    let addedAt: String
    let albumId: String?
    let artistId: String?
    let externalUrl: String?
}

/// Search result type
enum SearchType: String, Sendable {
    case track
    case album
    case artist
    case playlist
}

/// Track search result
struct SearchTrack: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let albumName: String
    let imageURL: URL?
    let durationMs: Int
    let albumId: String?
    let artistId: String?
    let externalUrl: String? // Web URL from Spotify API
}

/// Album search result
struct SearchAlbum: Sendable, Identifiable, DurationFormattable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let artistId: String?
    let imageURL: URL?
    let totalTracks: Int
    let releaseDate: String
    let totalDurationMs: Int?
    let externalUrl: String?

    init(id: String, name: String, uri: String, artistName: String, artistId: String? = nil, imageURL: URL?, totalTracks: Int, releaseDate: String, totalDurationMs: Int? = nil, externalUrl: String? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.artistName = artistName
        self.artistId = artistId
        self.imageURL = imageURL
        self.totalTracks = totalTracks
        self.releaseDate = releaseDate
        self.totalDurationMs = totalDurationMs
        self.externalUrl = externalUrl
    }

    init(from album: AlbumSimplified, totalDurationMs: Int? = nil) {
        id = album.id
        name = album.name
        uri = album.uri
        artistName = album.artistName
        artistId = nil // AlbumSimplified doesn't have artistId
        imageURL = album.imageURL
        totalTracks = album.trackCount
        releaseDate = album.releaseDate
        self.totalDurationMs = totalDurationMs
        externalUrl = nil // AlbumSimplified doesn't have externalUrl
    }
}

/// Artist search result
struct SearchArtist: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let imageURL: URL?
    let genres: [String]
    let followers: Int

    init(id: String, name: String, uri: String, imageURL: URL?, genres: [String], followers: Int) {
        self.id = id
        self.name = name
        self.uri = uri
        self.imageURL = imageURL
        self.genres = genres
        self.followers = followers
    }

    init(from artist: ArtistSimplified) {
        id = artist.id
        name = artist.name
        uri = artist.uri
        imageURL = artist.imageURL
        genres = artist.genres
        followers = artist.followers
    }
}

/// Playlist search result
struct SearchPlaylist: Sendable, Identifiable, DurationFormattable {
    let id: String
    let name: String
    let uri: String
    let description: String?
    let imageURL: URL?
    let trackCount: Int
    let ownerId: String
    let ownerName: String
    let totalDurationMs: Int?

    init(id: String, name: String, uri: String, description: String?, imageURL: URL?, trackCount: Int, ownerId: String, ownerName: String, totalDurationMs: Int? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
        self.description = description
        self.imageURL = imageURL
        self.trackCount = trackCount
        self.ownerId = ownerId
        self.ownerName = ownerName
        self.totalDurationMs = totalDurationMs
    }

    init(from playlist: PlaylistSimplified, totalDurationMs: Int? = nil) {
        id = playlist.id
        name = playlist.name
        uri = playlist.uri
        description = playlist.description
        imageURL = playlist.imageURL
        trackCount = playlist.trackCount
        ownerId = playlist.ownerId
        ownerName = playlist.ownerName
        self.totalDurationMs = totalDurationMs
    }
}

/// Search results wrapper
struct SearchResults: Sendable {
    let tracks: [SearchTrack]
    let albums: [SearchAlbum]
    let artists: [SearchArtist]
    let playlists: [SearchPlaylist]
}

/// Recently played context
struct PlaybackContext: Sendable {
    let type: String // "album", "playlist", "artist"
    let uri: String
}

/// Recently played item
struct RecentlyPlayedItem: Sendable, Identifiable {
    let id: String // Use played_at as ID since tracks can be played multiple times
    let track: SearchTrack
    let playedAt: String
    let context: PlaybackContext?
}

/// Recently played response wrapper
struct RecentlyPlayedResponse: Sendable {
    let items: [RecentlyPlayedItem]
}

/// Spotify Connect device
struct SpotifyDevice: Sendable, Identifiable {
    let id: String
    let name: String
    let type: String // "Computer", "Smartphone", "Speaker", etc.
    let isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let volumePercent: Int?
}

/// Devices response wrapper
struct DevicesResponse: Sendable {
    let devices: [SpotifyDevice]
}

/// Errors from Spotify API
enum SpotifyAPIError: Error, LocalizedError {
    case invalidURI
    case networkError(Error)
    case invalidResponse
    case unauthorized
    case notFound
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURI:
            "Invalid Spotify URI format"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            "Invalid response from Spotify"
        case .unauthorized:
            "Unauthorized - please log in again"
        case .notFound:
            "Track not found"
        case let .apiError(message):
            "Spotify API error: \(message)"
        }
    }
}

/// Spotify Web API client
enum SpotifyAPI {
    private static let baseURL = "https://api.spotify.com/v1"

    /// Parses a Spotify URI (spotify:track:xxx) and returns the track ID
    static func parseTrackURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle spotify:track:ID format
        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        // Handle https://open.spotify.com/track/ID format
        if let url = URL(string: trimmed),
           url.host == "open.spotify.com",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "track"
        {
            // Remove any query parameters from the track ID
            return url.pathComponents[2].components(separatedBy: "?").first
        }

        // If it looks like just an ID (22 chars, alphanumeric)
        if trimmed.count == 22, trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return trimmed
        }

        return nil
    }

    /// Fetches track metadata from Spotify Web API
    static func fetchTrackMetadata(trackId: String, accessToken: String) async throws -> TrackMetadata {
        let urlString = "\(baseURL)/tracks/\(trackId)?fields=id,name,duration_ms,artists(name),album(name,images),preview_url"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let durationMs = json["duration_ms"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        // Extract artist name(s)
        var artistName = "Unknown Artist"
        if let artists = json["artists"] as? [[String: Any]] {
            let artistNames = artists.compactMap { $0["name"] as? String }
            artistName = artistNames.joined(separator: ", ")
        }

        // Extract album info
        var albumName = "Unknown Album"
        var albumImageURL: URL? = nil
        if let album = json["album"] as? [String: Any] {
            albumName = album["name"] as? String ?? "Unknown Album"

            if let images = album["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                albumImageURL = URL(string: urlString)
            }
        }

        // Extract preview URL
        var previewURL: URL? = nil
        if let previewUrlString = json["preview_url"] as? String {
            previewURL = URL(string: previewUrlString)
        }

        return TrackMetadata(
            id: id,
            name: name,
            artistName: artistName,
            albumName: albumName,
            albumImageURL: albumImageURL,
            durationMs: durationMs,
            previewURL: previewURL,
        )
    }

    /// Fetches user's playlists from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - limit: Number of playlists to fetch (max 50)
    ///   - offset: Offset for pagination
    static func fetchUserPlaylists(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> PlaylistsResponse {
        let urlString = "\(baseURL)/me/playlists?limit=\(limit)&offset=\(offset)&fields=items(id,name,uri,description,images,tracks(total,items(track(duration_ms))),public,owner(id,display_name)),total,next"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let items = json["items"] as? [[String: Any]],
              let total = json["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let playlists = items.compactMap { item -> PlaylistSimplified? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String,
                  let tracks = item["tracks"] as? [String: Any],
                  let trackCount = tracks["total"] as? Int,
                  let owner = item["owner"] as? [String: Any],
                  let ownerId = owner["id"] as? String
            else {
                return nil
            }

            let ownerName = owner["display_name"] as? String ?? ownerId
            let description = item["description"] as? String
            let isPublic = item["public"] as? Bool ?? false

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            // Calculate total duration from tracks
            var totalDurationMs: Int?
            if let items = tracks["items"] as? [[String: Any]] {
                let durations = items.compactMap { item -> Int? in
                    guard let track = item["track"] as? [String: Any],
                          let duration = track["duration_ms"] as? Int
                    else {
                        return nil
                    }
                    return duration
                }
                if !durations.isEmpty {
                    totalDurationMs = durations.reduce(0, +)
                }
            }

            return PlaylistSimplified(
                id: id,
                name: name,
                description: description,
                imageURL: imageURL,
                trackCount: trackCount,
                uri: uri,
                isPublic: isPublic,
                ownerId: ownerId,
                ownerName: ownerName,
                totalDurationMs: totalDurationMs,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return PlaylistsResponse(
            playlists: playlists,
            total: total,
            hasMore: hasMore,
            nextOffset: nextOffset,
        )
    }

    /// Fetches a single playlist's details from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: Playlist ID
    static func fetchPlaylistDetails(accessToken: String, playlistId: String) async throws -> SearchPlaylist {
        // Add fields parameter to request only what we need, and market=from_token for region-specific playlists
        let urlString = "\(baseURL)/playlists/\(playlistId)?fields=id,name,description,images,tracks(total,items(track(duration_ms))),uri,public,owner(id,display_name)&market=from_token"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String,
              let tracks = json["tracks"] as? [String: Any],
              let trackCount = tracks["total"] as? Int,
              let owner = json["owner"] as? [String: Any],
              let ownerId = owner["id"] as? String
        else {
            throw SpotifyAPIError.invalidResponse
        }

        // Owner's display_name can be null, fall back to id
        let ownerName = owner["display_name"] as? String ?? ownerId

        let description = json["description"] as? String

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        // Calculate total duration from tracks
        var totalDurationMs: Int?
        if let items = tracks["items"] as? [[String: Any]] {
            let durations = items.compactMap { item -> Int? in
                guard let track = item["track"] as? [String: Any],
                      let duration = track["duration_ms"] as? Int
                else {
                    return nil
                }
                return duration
            }
            if !durations.isEmpty {
                totalDurationMs = durations.reduce(0, +)
            }
        }

        return SearchPlaylist(
            id: id,
            name: name,
            uri: uri,
            description: description,
            imageURL: imageURL,
            trackCount: trackCount,
            ownerId: ownerId,
            ownerName: ownerName,
            totalDurationMs: totalDurationMs,
        )
    }

    /// Fetches a single album's details from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - albumId: Album ID
    static func fetchAlbumDetails(accessToken: String, albumId: String) async throws -> SearchAlbum {
        let urlString = "\(baseURL)/albums/\(albumId)?fields=id,name,uri,total_tracks,release_date,artists(id,name),images,tracks(items(duration_ms)),external_urls(spotify)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String,
              let totalTracks = json["total_tracks"] as? Int,
              let releaseDate = json["release_date"] as? String,
              let artists = json["artists"] as? [[String: Any]]
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let artistName = artists.first?["name"] as? String ?? "Unknown Artist"
        let artistId = artists.first?["id"] as? String

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        // Calculate total duration from tracks
        var totalDurationMs: Int?
        if let tracksObj = json["tracks"] as? [String: Any],
           let items = tracksObj["items"] as? [[String: Any]]
        {
            let durations = items.compactMap { $0["duration_ms"] as? Int }
            if !durations.isEmpty {
                totalDurationMs = durations.reduce(0, +)
            }
        }

        // Parse external URL
        let externalUrls = json["external_urls"] as? [String: Any]
        let externalUrl = externalUrls?["spotify"] as? String

        return SearchAlbum(
            id: id,
            name: name,
            uri: uri,
            artistName: artistName,
            artistId: artistId,
            imageURL: imageURL,
            totalTracks: totalTracks,
            releaseDate: releaseDate,
            totalDurationMs: totalDurationMs,
            externalUrl: externalUrl,
        )
    }

    /// Fetches a single artist's details from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - artistId: Artist ID
    static func fetchArtistDetails(accessToken: String, artistId: String) async throws -> SearchArtist {
        let urlString = "\(baseURL)/artists/\(artistId)?fields=id,name,uri,genres,followers(total),images"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let genres = json["genres"] as? [String] ?? []
        let followers = (json["followers"] as? [String: Any])?["total"] as? Int ?? 0

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        return SearchArtist(
            id: id,
            name: name,
            uri: uri,
            imageURL: imageURL,
            genres: genres,
            followers: followers,
        )
    }

    /// Fetches user's saved albums from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - limit: Number of albums to fetch (max 50)
    ///   - offset: Offset for pagination
    static func fetchUserAlbums(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> AlbumsResponse {
        let urlString = "\(baseURL)/me/albums?limit=\(limit)&offset=\(offset)&fields=items(album(id,name,uri,total_tracks,release_date,album_type,artists(name),images,tracks(items(duration_ms)))),total,next"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let items = json["items"] as? [[String: Any]],
              let total = json["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let albums = items.compactMap { item -> AlbumSimplified? in
            guard let album = item["album"] as? [String: Any],
                  let id = album["id"] as? String,
                  let name = album["name"] as? String,
                  let uri = album["uri"] as? String,
                  let totalTracks = album["total_tracks"] as? Int,
                  let releaseDate = album["release_date"] as? String,
                  let albumType = album["album_type"] as? String
            else {
                return nil
            }

            var artistName = "Unknown Artist"
            if let artists = album["artists"] as? [[String: Any]] {
                let artistNames = artists.compactMap { $0["name"] as? String }
                artistName = artistNames.joined(separator: ", ")
            }

            var imageURL: URL?
            if let images = album["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            // Calculate total duration from tracks
            var totalDurationMs: Int?
            if let tracksObj = album["tracks"] as? [String: Any],
               let items = tracksObj["items"] as? [[String: Any]]
            {
                let durations = items.compactMap { $0["duration_ms"] as? Int }
                if !durations.isEmpty {
                    totalDurationMs = durations.reduce(0, +)
                }
            }

            return AlbumSimplified(
                id: id,
                name: name,
                artistName: artistName,
                imageURL: imageURL,
                trackCount: totalTracks,
                uri: uri,
                releaseDate: releaseDate,
                albumType: albumType,
                totalDurationMs: totalDurationMs,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return AlbumsResponse(
            albums: albums,
            total: total,
            hasMore: hasMore,
            nextOffset: nextOffset,
        )
    }

    /// Fetches user's followed artists from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - limit: Number of artists to fetch (max 50)
    ///   - after: Cursor for pagination (artist ID)
    static func fetchUserArtists(accessToken: String, limit: Int = 50, after: String? = nil) async throws -> ArtistsResponse {
        var urlString = "\(baseURL)/me/following?type=artist&limit=\(limit)&fields=artists(items(id,name,uri,genres,followers(total),images),total,cursors)"
        if let after {
            urlString += "&after=\(after)"
        }
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artistsContainer = json["artists"] as? [String: Any],
              let items = artistsContainer["items"] as? [[String: Any]],
              let total = artistsContainer["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let artists = items.compactMap { item -> ArtistSimplified? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String
            else {
                return nil
            }

            let genres = (item["genres"] as? [String]) ?? []
            let followersDict = item["followers"] as? [String: Any]
            let followers = followersDict?["total"] as? Int ?? 0

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            return ArtistSimplified(
                id: id,
                name: name,
                imageURL: imageURL,
                uri: uri,
                genres: genres,
                followers: followers,
            )
        }

        let cursors = artistsContainer["cursors"] as? [String: Any]
        let afterCursor = cursors?["after"] as? String
        let hasMore = afterCursor != nil
        let nextOffset = 0 // Artists use cursor-based pagination, not offset

        return ArtistsResponse(
            artists: artists,
            total: total,
            hasMore: hasMore,
            nextOffset: nextOffset,
        )
    }

    /// Fetches user's saved tracks (favorites) from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - limit: Number of tracks to fetch (max 50)
    ///   - offset: Offset for pagination
    static func fetchUserSavedTracks(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> SavedTracksResponse {
        let urlString = "\(baseURL)/me/tracks?limit=\(limit)&offset=\(offset)&fields=items(track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify)),added_at),total,next"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse JSON response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let items = json["items"] as? [[String: Any]],
              let total = json["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let tracks = items.compactMap { item -> SavedTrack? in
            guard let track = item["track"] as? [String: Any],
                  let id = track["id"] as? String,
                  let name = track["name"] as? String,
                  let uri = track["uri"] as? String,
                  let durationMs = track["duration_ms"] as? Int,
                  let addedAt = item["added_at"] as? String
            else {
                return nil
            }

            var artistName = "Unknown Artist"
            var artistId: String?
            if let artists = track["artists"] as? [[String: Any]] {
                let artistNames = artists.compactMap { $0["name"] as? String }
                artistName = artistNames.joined(separator: ", ")
                artistId = artists.first?["id"] as? String
            }

            var albumName = "Unknown Album"
            var albumId: String?
            var imageURL: URL?
            if let album = track["album"] as? [String: Any] {
                albumName = album["name"] as? String ?? "Unknown Album"
                albumId = album["id"] as? String

                if let images = album["images"] as? [[String: Any]],
                   let firstImage = images.first,
                   let urlString = firstImage["url"] as? String
                {
                    imageURL = URL(string: urlString)
                }
            }

            let externalUrls = track["external_urls"] as? [String: Any]
            let externalUrl = externalUrls?["spotify"] as? String

            return SavedTrack(
                id: id,
                name: name,
                artistName: artistName,
                albumName: albumName,
                imageURL: imageURL,
                durationMs: durationMs,
                uri: uri,
                addedAt: addedAt,
                albumId: albumId,
                artistId: artistId,
                externalUrl: externalUrl,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return SavedTracksResponse(
            tracks: tracks,
            total: total,
            hasMore: hasMore,
            nextOffset: nextOffset,
        )
    }

    /// Saves a track to user's library (favorites)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackId: The Spotify ID of the track to save
    static func saveTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create request body
        let body = ["ids": [trackId]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201:
            // Success - track saved
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Checks if a track is saved in user's library
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackId: The Spotify ID of the track to check
    /// - Returns: True if track is saved, false otherwise
    static func checkSavedTrack(accessToken: String, trackId: String) async throws -> Bool {
        let result = try await checkSavedTracks(accessToken: accessToken, trackIds: [trackId])
        return result[trackId] ?? false
    }

    /// Batch checks if multiple tracks are saved in user's library
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackIds: Array of Spotify track IDs to check (max 50 per request)
    /// - Returns: Dictionary mapping track ID to saved status
    static func checkSavedTracks(accessToken: String, trackIds: [String]) async throws -> [String: Bool] {
        guard !trackIds.isEmpty else { return [:] }

        // Spotify API allows max 50 IDs per request
        let batchSize = 50
        var results: [String: Bool] = [:]

        for batchStart in stride(from: 0, to: trackIds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, trackIds.count)
            let batch = Array(trackIds[batchStart ..< batchEnd])
            let idsParam = batch.joined(separator: ",")

            let urlString = "\(baseURL)/me/tracks/contains?ids=\(idsParam)"
            #if DEBUG
                apiLogger.debug("[GET] \(urlString)")
            #endif

            guard let url = URL(string: urlString) else {
                throw SpotifyAPIError.invalidURI
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw SpotifyAPIError.networkError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Bool],
                      jsonArray.count == batch.count
                else {
                    throw SpotifyAPIError.invalidResponse
                }
                // Map results back to track IDs
                for (index, trackId) in batch.enumerated() {
                    results[trackId] = jsonArray[index]
                }
            case 401:
                throw SpotifyAPIError.unauthorized
            default:
                if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = errorJson["error"] as? [String: Any],
                   let message = error["message"] as? String
                {
                    throw SpotifyAPIError.apiError(message)
                }
                throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }

        return results
    }

    /// Removes a track from user's saved tracks (unfavorites)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackId: The Spotify ID of the track to remove
    static func removeSavedTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks?ids=\(trackId)"
        #if DEBUG
            apiLogger.debug("[DELETE] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            // Success - track removed
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Album Tracks

    /// Fetches tracks for a specific album
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - albumId: The Spotify ID of the album
    static func fetchAlbumTracks(accessToken: String, albumId: String) async throws -> [AlbumTrack] {
        let urlString = "\(baseURL)/albums/\(albumId)/tracks?limit=50&fields=items(id,name,uri,duration_ms,track_number,artists(id,name),external_urls(spotify))"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let tracks = items.compactMap { item -> AlbumTrack? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let durationMs = item["duration_ms"] as? Int,
                      let trackNumber = item["track_number"] as? Int
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let externalUrls = item["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return AlbumTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    durationMs: durationMs,
                    trackNumber: trackNumber,
                    artistId: artistId,
                    externalUrl: externalUrl,
                )
            }

            return tracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Playlist Tracks

    /// Fetches tracks for a specific playlist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The Spotify ID of the playlist
    static func fetchPlaylistTracks(accessToken: String, playlistId: String) async throws -> [PlaylistTrack] {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks?limit=50&fields=items(track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify)),added_at)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let tracks = items.compactMap { item -> PlaylistTrack? in
                guard let track = item["track"] as? [String: Any],
                      let id = track["id"] as? String,
                      let name = track["name"] as? String,
                      let uri = track["uri"] as? String,
                      let durationMs = track["duration_ms"] as? Int
                else {
                    return nil
                }

                let artistsArray = track["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = track["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String ?? ""
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = track["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                let addedAt = item["added_at"] as? String ?? ""

                return PlaylistTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs,
                    addedAt: addedAt,
                    albumId: albumId,
                    artistId: artistId,
                    externalUrl: externalUrl,
                )
            }

            return tracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Artist Top Tracks

    /// Fetches top tracks for a specific artist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - artistId: The Spotify ID of the artist
    static func fetchArtistTopTracks(accessToken: String, artistId: String) async throws -> [SearchTrack] {
        // Use US market by default (required parameter)
        // Note: top-tracks endpoint doesn't support fields parameter, returns full track objects
        let urlString = "\(baseURL)/artists/\(artistId)/top-tracks?market=US"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let topTracks = tracks.compactMap { item -> SearchTrack? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let durationMs = item["duration_ms"] as? Int
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = item["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String ?? ""
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = item["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return SearchTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs,
                    albumId: albumId,
                    artistId: artistId,
                    externalUrl: externalUrl,
                )
            }

            return topTracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Artist Albums

    /// Fetches albums for a specific artist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - artistId: The Spotify ID of the artist
    ///   - limit: Maximum number of albums to return (default 50)
    /// - Returns: Array of albums by the artist
    static func fetchArtistAlbums(
        accessToken: String,
        artistId: String,
        limit: Int = 50,
    ) async throws -> [SearchAlbum] {
        let urlString = "\(baseURL)/artists/\(artistId)/albums?include_groups=album,single&market=US&limit=\(limit)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let albums = items.compactMap { item -> SearchAlbum? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let totalTracks = item["total_tracks"] as? Int,
                      let releaseDate = item["release_date"] as? String
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"

                let images = item["images"] as? [[String: Any]]
                let imageURLString = images?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                return SearchAlbum(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    imageURL: imageURL,
                    totalTracks: totalTracks,
                    releaseDate: releaseDate,
                )
            }

            return albums
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Recommendations (Radio)

    /// Fetches track recommendations based on a seed track (for "Start Radio" feature)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - seedTrackId: The Spotify ID of the seed track
    ///   - limit: Number of tracks to return (default 50, max 100)
    /// - Returns: Array of recommended tracks
    static func fetchRecommendations(
        accessToken: String,
        seedTrackId: String,
        limit: Int = 50,
    ) async throws -> [SearchTrack] {
        let urlString = "\(baseURL)/recommendations?seed_tracks=\(seedTrackId)&limit=\(limit)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["tracks"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let recommendedTracks = tracks.compactMap { item -> SearchTrack? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let durationMs = item["duration_ms"] as? Int
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = item["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String ?? ""
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = item["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return SearchTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs,
                    albumId: albumId,
                    artistId: artistId,
                    externalUrl: externalUrl,
                )
            }

            return recommendedTracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            // Try to get actual error message from Spotify
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError("Recommendations API: \(message)")
            }
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Search

    /// Performs a search across Spotify's catalog
    static func search(
        accessToken: String,
        query: String,
        types: [SearchType] = [.track, .album, .artist, .playlist],
        limit: Int = 20,
    ) async throws -> SearchResults {
        let typesParam = types.map(\.rawValue).joined(separator: ",")
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let urlString = "\(baseURL)/search?q=\(encodedQuery)&type=\(typesParam)&limit=\(limit)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyAPIError.invalidResponse
            }

            var tracks: [SearchTrack] = []
            var albums: [SearchAlbum] = []
            var artists: [SearchArtist] = []
            var playlists: [SearchPlaylist] = []

            // Parse tracks
            if let tracksObj = json["tracks"] as? [String: Any],
               let items = tracksObj["items"] as? [[String: Any]]
            {
                tracks = items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String,
                          let durationMs = item["duration_ms"] as? Int
                    else {
                        return nil
                    }

                    let artistsArray = item["artists"] as? [[String: Any]]
                    let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                    let artistId = artistsArray?.first?["id"] as? String

                    let albumData = item["album"] as? [String: Any]
                    let albumName = albumData?["name"] as? String ?? ""
                    let albumId = albumData?["id"] as? String
                    let albumImages = albumData?["images"] as? [[String: Any]]
                    let imageURLString = albumImages?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    let externalUrls = item["external_urls"] as? [String: Any]
                    let externalUrl = externalUrls?["spotify"] as? String

                    return SearchTrack(
                        id: id,
                        name: name,
                        uri: uri,
                        artistName: artistName,
                        albumName: albumName,
                        imageURL: imageURL,
                        durationMs: durationMs,
                        albumId: albumId,
                        artistId: artistId,
                        externalUrl: externalUrl,
                    )
                }
            }

            // Parse albums
            if let albumsObj = json["albums"] as? [String: Any],
               let items = albumsObj["items"] as? [[String: Any]]
            {
                albums = items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String
                    else {
                        return nil
                    }

                    let artistName = (item["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "Unknown"
                    let totalTracks = item["total_tracks"] as? Int ?? 0
                    let releaseDate = item["release_date"] as? String ?? ""
                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    return SearchAlbum(
                        id: id,
                        name: name,
                        uri: uri,
                        artistName: artistName,
                        imageURL: imageURL,
                        totalTracks: totalTracks,
                        releaseDate: releaseDate,
                    )
                }
            }

            // Parse artists
            if let artistsObj = json["artists"] as? [String: Any],
               let items = artistsObj["items"] as? [[String: Any]]
            {
                artists = items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String
                    else {
                        return nil
                    }

                    let genres = item["genres"] as? [String] ?? []
                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }
                    let followers = (item["followers"] as? [String: Any])?["total"] as? Int ?? 0

                    return SearchArtist(
                        id: id,
                        name: name,
                        uri: uri,
                        imageURL: imageURL,
                        genres: genres,
                        followers: followers,
                    )
                }
            }

            // Parse playlists
            if let playlistsObj = json["playlists"] as? [String: Any],
               let itemsArray = playlistsObj["items"] as? [Any]
            {
                // Filter out NSNull values and cast to dictionaries
                let items = itemsArray.compactMap { $0 as? [String: Any] }

                playlists = items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String
                    else {
                        return nil
                    }

                    let description = item["description"] as? String
                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }
                    let trackCount = (item["tracks"] as? [String: Any])?["total"] as? Int ?? 0
                    let owner = item["owner"] as? [String: Any]
                    let ownerId = owner?["id"] as? String ?? ""
                    let ownerName = owner?["display_name"] as? String ?? ownerId

                    return SearchPlaylist(
                        id: id,
                        name: name,
                        uri: uri,
                        description: description,
                        imageURL: imageURL,
                        trackCount: trackCount,
                        ownerId: ownerId,
                        ownerName: ownerName.isEmpty ? "Unknown" : ownerName,
                    )
                }
            }

            return SearchResults(
                tracks: tracks,
                albums: albums,
                artists: artists,
                playlists: playlists,
            )

        case 401:
            throw SpotifyAPIError.unauthorized

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Recently Played

    /// Fetches recently played tracks
    static func fetchRecentlyPlayed(
        accessToken: String,
        limit: Int = 50,
    ) async throws -> RecentlyPlayedResponse {
        let urlString = "\(baseURL)/me/player/recently-played?limit=\(limit)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyAPIError.invalidResponse
            }

            guard let itemsArray = json["items"] as? [[String: Any]] else {
                throw SpotifyAPIError.invalidResponse
            }

            let items = itemsArray.compactMap { item -> RecentlyPlayedItem? in
                guard let trackData = item["track"] as? [String: Any],
                      let trackId = trackData["id"] as? String,
                      let trackName = trackData["name"] as? String,
                      let trackUri = trackData["uri"] as? String,
                      let durationMs = trackData["duration_ms"] as? Int,
                      let playedAt = item["played_at"] as? String
                else {
                    return nil
                }

                let artistsArray = trackData["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = trackData["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String ?? ""
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = trackData["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                let track = SearchTrack(
                    id: trackId,
                    name: trackName,
                    uri: trackUri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs,
                    albumId: albumId,
                    artistId: artistId,
                    externalUrl: externalUrl,
                )

                // Parse context if available
                var context: PlaybackContext? = nil
                if let contextData = item["context"] as? [String: Any],
                   let contextType = contextData["type"] as? String,
                   let contextUri = contextData["uri"] as? String
                {
                    context = PlaybackContext(type: contextType, uri: contextUri)
                }

                return RecentlyPlayedItem(
                    id: playedAt, // Use playedAt as unique ID
                    track: track,
                    playedAt: playedAt,
                    context: context,
                )
            }

            return RecentlyPlayedResponse(items: items)

        case 401:
            throw SpotifyAPIError.unauthorized

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Spotify Connect (Devices)

    /// Fetches available Spotify Connect devices
    static func fetchAvailableDevices(accessToken: String) async throws -> DevicesResponse {
        let urlString = "\(baseURL)/me/player/devices"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devicesArray = json["devices"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let devices = devicesArray.compactMap { deviceData -> SpotifyDevice? in
                guard let id = deviceData["id"] as? String,
                      let name = deviceData["name"] as? String,
                      let type = deviceData["type"] as? String,
                      let isActive = deviceData["is_active"] as? Bool,
                      let isPrivateSession = deviceData["is_private_session"] as? Bool,
                      let isRestricted = deviceData["is_restricted"] as? Bool
                else {
                    return nil
                }

                let volumePercent = deviceData["volume_percent"] as? Int

                return SpotifyDevice(
                    id: id,
                    name: name,
                    type: type,
                    isActive: isActive,
                    isPrivateSession: isPrivateSession,
                    isRestricted: isRestricted,
                    volumePercent: volumePercent,
                )
            }

            return DevicesResponse(devices: devices)

        case 401:
            throw SpotifyAPIError.unauthorized

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Transfers playback to a different device
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - deviceId: The device ID to transfer playback to
    ///   - play: Whether to start playing on the new device (default: true)
    static func transferPlayback(accessToken: String, deviceId: String, play: Bool = true) async throws {
        let urlString = "\(baseURL)/me/player"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create request body
        let body: [String: Any] = [
            "device_ids": [deviceId],
            "play": play,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 204:
            // Success - playback transferred
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Device is restricted and cannot accept playback")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Playlist Management

    /// Gets the current user's Spotify user ID
    /// - Parameter accessToken: Spotify access token
    /// - Returns: The user's Spotify ID
    static func getCurrentUserId(accessToken: String) async throws -> String {
        let urlString = "\(baseURL)/me"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userId = json["id"] as? String
            else {
                throw SpotifyAPIError.invalidResponse
            }
            return userId

        case 401:
            throw SpotifyAPIError.unauthorized

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Creates a new playlist for the user
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - userId: The user's Spotify ID
    ///   - name: The name for the new playlist
    ///   - description: Optional description for the playlist
    ///   - isPublic: Whether the playlist should be public (default: false)
    /// - Returns: The created playlist
    static func createPlaylist(
        accessToken: String,
        userId: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
    ) async throws -> PlaylistSimplified {
        let urlString = "\(baseURL)/users/\(userId)/playlists"
        #if DEBUG
            apiLogger.debug("[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "description": description ?? "",
            "public": isPublic,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let name = json["name"] as? String,
                  let uri = json["uri"] as? String,
                  let owner = json["owner"] as? [String: Any],
                  let ownerId = owner["id"] as? String
            else {
                throw SpotifyAPIError.invalidResponse
            }

            // Owner's display_name can be null, fall back to id
            let ownerName = owner["display_name"] as? String ?? ownerId

            let description = json["description"] as? String
            let isPublic = json["public"] as? Bool ?? false

            var imageURL: URL?
            if let images = json["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            return PlaylistSimplified(
                id: id,
                name: name,
                description: description,
                imageURL: imageURL,
                trackCount: 0,
                uri: uri,
                isPublic: isPublic,
                ownerId: ownerId,
                ownerName: ownerName,
                totalDurationMs: nil,
            )

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to create playlists for this user")

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Adds tracks to an existing playlist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist to add tracks to
    ///   - trackUris: Array of Spotify track URIs (e.g., "spotify:track:xxx")
    static func addTracksToPlaylist(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"
        #if DEBUG
            apiLogger.debug("[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["uris": trackUris]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 201:
            // Success - tracks added
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Updates playlist details (name and/or description)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist to update
    ///   - newName: New name for the playlist (optional)
    ///   - newDescription: New description for the playlist (optional)
    static func updatePlaylistDetails(
        accessToken: String,
        playlistId: String,
        newName: String? = nil,
        newDescription: String? = nil,
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let newName {
            body["name"] = newName
        }
        if let newDescription {
            body["description"] = newDescription
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Deletes (unfollows) a playlist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist to delete
    static func deletePlaylist(
        accessToken: String,
        playlistId: String,
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/followers"
        #if DEBUG
            apiLogger.debug("[DELETE] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to delete this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Removes tracks from a playlist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist
    ///   - trackUris: Array of track URIs to remove
    static func removeTracksFromPlaylist(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"
        #if DEBUG
            apiLogger.debug("[DELETE] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Format: { "tracks": [{ "uri": "spotify:track:xxx" }, ...] }
        let tracks = trackUris.map { ["uri": $0] }
        let body: [String: Any] = ["tracks": tracks]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Reorders tracks in a playlist
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist
    ///   - rangeStart: The position of the first track to be reordered
    ///   - insertBefore: The position where the tracks should be inserted
    ///   - rangeLength: Number of tracks to reorder (default 1)
    static func reorderPlaylistTracks(
        accessToken: String,
        playlistId: String,
        rangeStart: Int,
        insertBefore: Int,
        rangeLength: Int = 1,
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "range_start": rangeStart,
            "insert_before": insertBefore,
            "range_length": rangeLength,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201:
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Replaces all tracks in a playlist (used for reordering)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - playlistId: The ID of the playlist
    ///   - trackUris: Array of track URIs in the desired order
    static func replacePlaylistTracks(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["uris": trackUris]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201:
            break

        case 401:
            throw SpotifyAPIError.unauthorized

        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")

        case 404:
            throw SpotifyAPIError.notFound

        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
}
