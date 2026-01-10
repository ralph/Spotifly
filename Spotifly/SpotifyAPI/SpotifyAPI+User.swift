//
//  SpotifyAPI+User.swift
//  Spotifly
//
//  User-related API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - User Profile

    /// Gets the current user's Spotify user ID
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

    // MARK: - Recently Played

    /// Fetches the user's recently played tracks
    static func fetchRecentlyPlayed(accessToken: String, limit: Int = 50) async throws -> RecentlyPlayedResponse {
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let recentlyPlayedItems = items.compactMap { item -> RecentlyPlayedItem? in
                guard let track = item["track"] as? [String: Any],
                      let id = track["id"] as? String,
                      let name = track["name"] as? String,
                      let uri = track["uri"] as? String,
                      let durationMs = track["duration_ms"] as? Int,
                      let playedAt = item["played_at"] as? String
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

                let apiTrack = APITrack(
                    id: id,
                    addedAt: nil,
                    albumId: albumId,
                    albumName: albumName,
                    artistId: artistId,
                    artistName: artistName,
                    durationMs: durationMs,
                    externalUrl: externalUrl,
                    imageURL: imageURL,
                    name: name,
                    trackNumber: nil,
                    uri: uri,
                )

                var context: PlaybackContext?
                if let contextData = item["context"] as? [String: Any],
                   let contextType = contextData["type"] as? String,
                   let contextUri = contextData["uri"] as? String
                {
                    context = PlaybackContext(type: contextType, uri: contextUri)
                }

                return RecentlyPlayedItem(
                    id: playedAt,
                    context: context,
                    playedAt: playedAt,
                    track: apiTrack,
                )
            }

            return RecentlyPlayedResponse(items: recentlyPlayedItems)

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
