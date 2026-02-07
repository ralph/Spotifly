//
//  SpotifyAPI+Playlists.swift
//  Spotifly
//
//  Playlist-related API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - User Playlists

    /// Fetches user's playlists from Spotify Web API
    static func fetchUserPlaylists(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> PlaylistsResponse {
        let urlString = "\(baseURL)/me/playlists?limit=\(limit)&offset=\(offset)&fields=items(id,name,uri,description,images,items(total,items(item(duration_ms))),public,owner(id,display_name)),total,next"

        debugLog("SpotifyAPI", "[GET] \(urlString)")

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
            do {
                let decoded = try JSONDecoder().decode(UserPlaylistsCodable.self, from: data)
                let playlists = decoded.items.map { $0.toAPIPlaylist() }
                let hasMore = decoded.next != nil
                return PlaylistsResponse(
                    hasMore: hasMore,
                    nextOffset: hasMore ? offset + limit : nil,
                    playlists: playlists,
                    total: decoded.total,
                )
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Playlist Details

    /// Fetches a single playlist's details from Spotify Web API
    static func fetchPlaylistDetails(accessToken: String, playlistId: String) async throws -> APIPlaylist {
        let urlString = "\(baseURL)/playlists/\(playlistId)?fields=id,name,description,images,items(total,items(item(duration_ms))),uri,public,owner(id,display_name)&market=from_token"

        debugLog("SpotifyAPI", "[GET] \(urlString)")

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
            do {
                let playlist = try JSONDecoder().decode(PlaylistCodable.self, from: data)
                return playlist.toAPIPlaylist()
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Playlist Management

    /// Creates a new playlist for the current user
    static func createPlaylist(
        accessToken: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
    ) async throws -> APIPlaylist {
        let urlString = "\(baseURL)/me/playlists"

        debugLog("SpotifyAPI", "[POST] \(urlString)")

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
            do {
                let playlist = try JSONDecoder().decode(PlaylistCodable.self, from: data)
                return playlist.toAPIPlaylist()
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to create playlists for this user")
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Adds tracks to an existing playlist
    static func addTracksToPlaylist(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"

        debugLog("SpotifyAPI", "[POST] \(urlString)")

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
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Updates playlist details (name and/or description)
    static func updatePlaylistDetails(
        accessToken: String,
        playlistId: String,
        name: String? = nil,
        description: String? = nil,
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let description { body["description"] = description }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Deletes (unfollows) a playlist
    static func deletePlaylist(accessToken: String, playlistId: String) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/followers"

        debugLog("SpotifyAPI", "[DELETE] \(urlString)")

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
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to delete this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Follows (saves) a playlist to the user's library
    static func followPlaylist(accessToken: String, playlistId: String) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/followers"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Empty body required
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to follow this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Removes tracks from a playlist
    static func removeTracksFromPlaylist(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"

        debugLog("SpotifyAPI", "[DELETE] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let tracks = trackUris.map { ["uri": $0] }
        let body: [String: Any] = ["tracks": tracks]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Reorders tracks in a playlist
    static func reorderPlaylistTracks(
        accessToken: String,
        playlistId: String,
        rangeStart: Int,
        insertBefore: Int,
        rangeLength: Int = 1,
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

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
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Replaces all tracks in a playlist
    static func replacePlaylistTracks(
        accessToken: String,
        playlistId: String,
        trackUris: [String],
    ) async throws {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

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
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify this playlist")
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
