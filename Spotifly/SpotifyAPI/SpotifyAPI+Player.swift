//
//  SpotifyAPI+Player.swift
//  Spotifly
//
//  Playback and Spotify Connect API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - Devices

    /// Fetches available Spotify Connect devices
    static func fetchAvailableDevices(accessToken: String) async throws -> DevicesResponse {
        let urlString = "\(baseURL)/me/player/devices"

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
                let decoded = try JSONDecoder().decode(DevicesCodable.self, from: data)
                let devices = decoded.devices.compactMap { $0.toDevice() }
                return DevicesResponse(devices: devices)
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

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

    // MARK: - Transfer Playback

    /// Transfers playback to a different device
    /// - Parameters:
    ///   - deviceId: The device ID to transfer playback to
    ///   - accessToken: The access token for authentication
    ///   - play: Whether to start playing on the target device (default true)
    static func transferPlayback(toDeviceId deviceId: String, accessToken: String, play: Bool = true) async throws {
        let urlString = "\(baseURL)/me/player"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "device_ids": [deviceId],
            "play": play,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            // Success - no content returned
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
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
}
