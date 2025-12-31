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

/// Album track (from album tracks endpoint)
struct AlbumTrack: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let durationMs: Int
    let trackNumber: Int
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
}

/// Album search result
struct SearchAlbum: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artistName: String
    let imageURL: URL?
    let totalTracks: Int
    let releaseDate: String
}

/// Artist search result
struct SearchArtist: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let imageURL: URL?
    let genres: [String]
    let followers: Int
}

/// Playlist search result
struct SearchPlaylist: Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let description: String?
    let imageURL: URL?
    let trackCount: Int
    let ownerName: String
}

/// Search results wrapper
struct SearchResults: Sendable {
    let tracks: [SearchTrack]
    let albums: [SearchAlbum]
    let artists: [SearchArtist]
    let playlists: [SearchPlaylist]
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

    /// Saves a track to user's library (favorites)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackId: The Spotify ID of the track to save
    static func saveTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks"

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
        let urlString = "\(baseURL)/me/tracks/contains?ids=\(trackId)"

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
            // Parse JSON response - returns array of booleans
            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Bool],
                  let isSaved = jsonArray.first
            else {
                throw SpotifyAPIError.invalidResponse
            }
            return isSaved
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

    /// Removes a track from user's saved tracks (unfavorites)
    /// - Parameters:
    ///   - accessToken: Spotify access token
    ///   - trackId: The Spotify ID of the track to remove
    static func removeSavedTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks?ids=\(trackId)"

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
        let urlString = "\(baseURL)/albums/\(albumId)/tracks?limit=50"

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

                let artistName = (item["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "Unknown"

                return AlbumTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    durationMs: durationMs,
                    trackNumber: trackNumber
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
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks?limit=50"

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

                let artistName = (track["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "Unknown"
                let albumName = (track["album"] as? [String: Any])?["name"] as? String ?? ""
                let albumImages = (track["album"] as? [String: Any])?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }
                let addedAt = item["added_at"] as? String ?? ""

                return PlaylistTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs,
                    addedAt: addedAt
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
        let urlString = "\(baseURL)/artists/\(artistId)/top-tracks?market=US"

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

                let artistName = (item["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "Unknown"
                let albumName = (item["album"] as? [String: Any])?["name"] as? String ?? ""
                let albumImages = (item["album"] as? [String: Any])?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                return SearchTrack(
                    id: id,
                    name: name,
                    uri: uri,
                    artistName: artistName,
                    albumName: albumName,
                    imageURL: imageURL,
                    durationMs: durationMs
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

    // MARK: - Search

    /// Performs a search across Spotify's catalog
    static func search(
        accessToken: String,
        query: String,
        types: [SearchType] = [.track, .album, .artist, .playlist],
        limit: Int = 20
    ) async throws -> SearchResults {
        let typesParam = types.map(\.rawValue).joined(separator: ",")
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query

        let urlString = "\(baseURL)/search?q=\(encodedQuery)&type=\(typesParam)&limit=\(limit)"

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

                    let artistName = (item["artists"] as? [[String: Any]])?.first?["name"] as? String ?? "Unknown"
                    let albumName = (item["album"] as? [String: Any])?["name"] as? String ?? ""
                    let albumImages = (item["album"] as? [String: Any])?["images"] as? [[String: Any]]
                    let imageURLString = albumImages?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    return SearchTrack(
                        id: id,
                        name: name,
                        uri: uri,
                        artistName: artistName,
                        albumName: albumName,
                        imageURL: imageURL,
                        durationMs: durationMs
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
                        releaseDate: releaseDate
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
                        followers: followers
                    )
                }
            }

            // Parse playlists
            if let playlistsObj = json["playlists"] as? [String: Any],
               let items = playlistsObj["items"] as? [[String: Any]]
            {
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
                    let ownerName = (item["owner"] as? [String: Any])?["display_name"] as? String ?? "Unknown"

                    return SearchPlaylist(
                        id: id,
                        name: name,
                        uri: uri,
                        description: description,
                        imageURL: imageURL,
                        trackCount: trackCount,
                        ownerName: ownerName
                    )
                }
            }

            return SearchResults(
                tracks: tracks,
                albums: albums,
                artists: artists,
                playlists: playlists
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
}
