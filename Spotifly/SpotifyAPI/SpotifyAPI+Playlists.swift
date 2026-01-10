//
//  SpotifyAPI+Playlists.swift
//  Spotifly
//
//  Playlist-related API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - User Playlists

    /// Fetches user's playlists from Spotify Web API
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let total = json["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let playlists = items.compactMap { item -> APIPlaylist? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String,
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

            let tracksObj = item["tracks"] as? [String: Any]
            let trackCount = tracksObj?["total"] as? Int ?? 0

            var totalDurationMs: Int?
            if let trackItems = tracksObj?["items"] as? [[String: Any]] {
                let durations = trackItems.compactMap { trackItem -> Int? in
                    guard let track = trackItem["track"] as? [String: Any],
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

            return APIPlaylist(
                id: id,
                description: description,
                imageURL: imageURL,
                isPublic: isPublic,
                name: name,
                ownerId: ownerId,
                ownerName: ownerName,
                totalDurationMs: totalDurationMs,
                trackCount: trackCount,
                uri: uri,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return PlaylistsResponse(
            hasMore: hasMore,
            nextOffset: nextOffset,
            playlists: playlists,
            total: total,
        )
    }

    // MARK: - Playlist Details

    /// Fetches a single playlist's details from Spotify Web API
    static func fetchPlaylistDetails(accessToken: String, playlistId: String) async throws -> APIPlaylist {
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String,
              let owner = json["owner"] as? [String: Any],
              let ownerId = owner["id"] as? String
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let ownerName = owner["display_name"] as? String ?? ownerId
        let description = json["description"] as? String

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        let tracksObj = json["tracks"] as? [String: Any]
        let trackCount = tracksObj?["total"] as? Int ?? 0

        var totalDurationMs: Int?
        if let trackItems = tracksObj?["items"] as? [[String: Any]] {
            let durations = trackItems.compactMap { trackItem -> Int? in
                guard let track = trackItem["track"] as? [String: Any],
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

        return APIPlaylist(
            id: id,
            description: description,
            imageURL: imageURL,
            isPublic: nil,
            name: name,
            ownerId: ownerId,
            ownerName: ownerName,
            totalDurationMs: totalDurationMs,
            trackCount: trackCount,
            uri: uri,
        )
    }

    // MARK: - Playlist Management

    /// Creates a new playlist for the user
    static func createPlaylist(
        accessToken: String,
        userId: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false,
    ) async throws -> APIPlaylist {
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

            return APIPlaylist(
                id: id,
                description: description,
                imageURL: imageURL,
                isPublic: isPublic,
                name: name,
                ownerId: ownerId,
                ownerName: ownerName,
                totalDurationMs: nil,
                trackCount: 0,
                uri: uri,
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
    static func updatePlaylistDetails(
        accessToken: String,
        playlistId: String,
        name: String? = nil,
        description: String? = nil,
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
        if let name { body["name"] = name }
        if let description { body["description"] = description }
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
    static func deletePlaylist(accessToken: String, playlistId: String) async throws {
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

    /// Replaces all tracks in a playlist
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
        case 201:
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
