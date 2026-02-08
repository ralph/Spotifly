//
//  SpotifyAPI+User.swift
//  Spotifly
//
//  User-related API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - User Profile

    /// Gets the current user's full profile
    static func getCurrentUserProfile(accessToken: String) async throws -> UserProfile {
        let urlString = "\(baseURL)/me"

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
                let codable = try JSONDecoder().decode(UserProfileCodable.self, from: data)
                return UserProfile(from: codable)
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.forbidden
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Recently Played

    /// Fetches the user's recently played tracks
    static func fetchRecentlyPlayed(accessToken: String, limit: Int = 50) async throws -> RecentlyPlayedResponse {
        let urlString = "\(baseURL)/me/player/recently-played?limit=\(limit)"

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
                let decoded = try JSONDecoder().decode(RecentlyPlayedCodable.self, from: data)
                return decoded.toRecentlyPlayedResponse()
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
