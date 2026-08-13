//
//  SpotifyAPI+Playlists.swift
//  Spotifly
//
//  Playlist-related API calls.
//

import Foundation

extension SpotifyAPI {
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
        if let name {
            body["name"] = name
        }
        if let description {
            body["description"] = description
        }
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
}
