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

    // MARK: - Remote Playback Control

    /// Pauses playback on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    static func pausePlayback(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/pause"

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Resumes playback on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    static func resumePlayback(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/play"

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Skips to the next track on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    static func skipToNext(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/next"

        #if DEBUG
            debugLog("SpotifyAPI", "[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Skips to the previous track on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    static func skipToPrevious(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/previous"

        #if DEBUG
            debugLog("SpotifyAPI", "[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Seeks to a position in the currently playing track via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    /// - Parameters:
    ///   - accessToken: The access token for authentication
    ///   - positionMs: The position in milliseconds to seek to
    static func seekToPosition(accessToken: String, positionMs: Int) async throws {
        let urlString = "\(baseURL)/me/player/seek?position_ms=\(positionMs)"

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Sets the playback volume on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    /// - Parameters:
    ///   - accessToken: The access token for authentication
    ///   - percent: Volume level 0–100
    static func setVolume(accessToken: String, percent: Int) async throws {
        let percent = max(0, min(100, percent))
        let urlString = "\(baseURL)/me/player/volume?volume_percent=\(percent)"

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Enables or disables shuffle on the active device via Web API.
    /// Use this when controlling a remote device (not the local Spirc).
    /// - Parameters:
    ///   - accessToken: The access token for authentication
    ///   - enabled: Whether shuffle should be enabled
    static func setShuffle(accessToken: String, enabled: Bool) async throws {
        let urlString = "\(baseURL)/me/player/shuffle?state=\(enabled)"
        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(urlString)")
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success
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
