//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify Web API client for fetching track metadata
//

import Foundation

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
struct PlaylistSimplified: Sendable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let imageURL: URL?
    let trackCount: Int
    let uri: String
    let isPublic: Bool
    let ownerName: String
}

/// Response wrapper for playlists endpoint
struct PlaylistsResponse: Sendable {
    let playlists: [PlaylistSimplified]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
}

/// Simplified album metadata from Spotify
struct AlbumSimplified: Sendable, Identifiable {
    let id: String
    let name: String
    let artistName: String
    let imageURL: URL?
    let trackCount: Int
    let uri: String
    let releaseDate: String
    let albumType: String
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
}

/// Response wrapper for saved tracks endpoint
struct SavedTracksResponse: Sendable {
    let tracks: [SavedTrack]
    let total: Int
    let hasMore: Bool
    let nextOffset: Int?
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
        let urlString = "\(baseURL)/tracks/\(trackId)"

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
        let urlString = "\(baseURL)/me/playlists?limit=\(limit)&offset=\(offset)"

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
                  let ownerName = owner["display_name"] as? String
            else {
                return nil
            }

            let description = item["description"] as? String
            let isPublic = item["public"] as? Bool ?? false

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
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
                trackCount: trackCount,
                uri: uri,
                isPublic: isPublic,
                ownerName: ownerName,
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

    /// Fetches user's saved albums from Spotify Web API
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - limit: Number of albums to fetch (max 50)
    ///   - offset: Offset for pagination
    static func fetchUserAlbums(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> AlbumsResponse {
        let urlString = "\(baseURL)/me/albums?limit=\(limit)&offset=\(offset)"

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

            return AlbumSimplified(
                id: id,
                name: name,
                artistName: artistName,
                imageURL: imageURL,
                trackCount: totalTracks,
                uri: uri,
                releaseDate: releaseDate,
                albumType: albumType,
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
        var urlString = "\(baseURL)/me/following?type=artist&limit=\(limit)"
        if let after {
            urlString += "&after=\(after)"
        }

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
        let urlString = "\(baseURL)/me/tracks?limit=\(limit)&offset=\(offset)"

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
            if let artists = track["artists"] as? [[String: Any]] {
                let artistNames = artists.compactMap { $0["name"] as? String }
                artistName = artistNames.joined(separator: ", ")
            }

            var albumName = "Unknown Album"
            var imageURL: URL?
            if let album = track["album"] as? [String: Any] {
                albumName = album["name"] as? String ?? "Unknown Album"

                if let images = album["images"] as? [[String: Any]],
                   let firstImage = images.first,
                   let urlString = firstImage["url"] as? String
                {
                    imageURL = URL(string: urlString)
                }
            }

            return SavedTrack(
                id: id,
                name: name,
                artistName: artistName,
                albumName: albumName,
                imageURL: imageURL,
                durationMs: durationMs,
                uri: uri,
                addedAt: addedAt,
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
}
