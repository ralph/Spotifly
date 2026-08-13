//
//  SpotifyAPI+Player.swift
//  Spotifly
//
//  Playback and Spotify Connect API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - Queue

    /// Response from GET /me/player/queue
    struct QueueResponse: Decodable {
        let currentlyPlaying: TrackCodable?
        let queue: [TrackCodable]

        enum CodingKeys: String, CodingKey {
            case currentlyPlaying = "currently_playing"
            case queue
        }
    }

    /// Fetches the current playback queue from Spotify Web API.
    /// Returns the currently playing track and upcoming queue.
    /// - Parameter accessToken: The access token for authentication
    /// - Returns: QueueResponse containing current track and queue
    static func fetchQueue(accessToken: String) async throws -> QueueResponse {
        let urlString = "\(baseURL)/me/player/queue"

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
            return try JSONDecoder().decode(QueueResponse.self, from: data)
        case 204:
            // No content - nothing playing
            return QueueResponse(currentlyPlaying: nil, queue: [])
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Playback State

    /// Response from GET /me/player
    struct PlaybackStateResponse: Decodable {
        let device: DeviceCodable?
        let repeatState: String?
        let shuffleState: Bool?
        let timestamp: Int64?
        let progressMs: Int?
        let isPlaying: Bool
        let item: TrackCodable?

        enum CodingKeys: String, CodingKey {
            case device
            case repeatState = "repeat_state"
            case shuffleState = "shuffle_state"
            case timestamp
            case progressMs = "progress_ms"
            case isPlaying = "is_playing"
            case item
        }
    }

    /// Fetches the current playback state from Spotify Web API.
    /// Returns the currently playing track, device, and playback position.
    /// - Parameter accessToken: The access token for authentication
    /// - Returns: PlaybackStateResponse containing current playback state, or nil if nothing playing
    static func fetchPlaybackState(accessToken: String) async throws -> PlaybackStateResponse? {
        let urlString = "\(baseURL)/me/player?market=from_token"

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
            return try JSONDecoder().decode(PlaybackStateResponse.self, from: data)
        case 204:
            // No content - nothing playing
            return nil
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
