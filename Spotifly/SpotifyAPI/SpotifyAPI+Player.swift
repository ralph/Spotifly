//
//  SpotifyAPI+Player.swift
//  Spotifly
//
//  Playback and Spotify Connect API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Devices

    /// Fetches available Spotify Connect devices
    static func fetchAvailableDevices(accessToken: String) async throws -> DevicesResponse {
        let urlString = "\(baseURL)/me/player/devices"
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
                  let devicesArray = json["devices"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let devices = devicesArray.compactMap { item -> SpotifyDevice? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let type = item["type"] as? String
                else {
                    return nil
                }

                return SpotifyDevice(
                    id: id,
                    isActive: item["is_active"] as? Bool ?? false,
                    isPrivateSession: item["is_private_session"] as? Bool ?? false,
                    isRestricted: item["is_restricted"] as? Bool ?? false,
                    name: name,
                    type: type,
                    volumePercent: item["volume_percent"] as? Int,
                )
            }

            return DevicesResponse(devices: devices)

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

    /// Transfers playback to a specific device
    static func transferPlayback(accessToken: String, deviceId: String, play: Bool = true) async throws {
        let urlString = "\(baseURL)/me/player"
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
            "device_ids": [deviceId],
            "play": play,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 204:
            return
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

    // MARK: - Playback Control

    /// Starts playback on a device
    static func startPlayback(
        accessToken: String,
        deviceId: String? = nil,
        contextUri: String? = nil,
        trackUris: [String]? = nil,
        offsetPosition: Int? = nil,
        positionMs: Int? = nil,
    ) async throws {
        var urlString = "\(baseURL)/me/player/play"
        if let deviceId {
            urlString += "?device_id=\(deviceId)"
        }
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
        if let contextUri { body["context_uri"] = contextUri }
        if let trackUris { body["uris"] = trackUris }
        if let offsetPosition { body["offset"] = ["position": offsetPosition] }
        if let positionMs { body["position_ms"] = positionMs }
        if !body.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 202, 204:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.apiError("No active device found")
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

    /// Pauses playback
    static func pausePlayback(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/pause"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SpotifyAPIError.unauthorized
        }
    }

    /// Resumes playback
    static func resumePlayback(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/play"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SpotifyAPIError.unauthorized
        }
    }

    /// Skips to the next track
    static func skipToNext(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/next"
        #if DEBUG
            apiLogger.debug("[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SpotifyAPIError.unauthorized
        }
    }

    /// Skips to the previous track
    static func skipToPrevious(accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/previous"
        #if DEBUG
            apiLogger.debug("[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw SpotifyAPIError.unauthorized
        }
    }

    /// Seeks to a position in the current track
    static func seekToPosition(accessToken: String, positionMs: Int) async throws {
        let urlString = "\(baseURL)/me/player/seek?position_ms=\(positionMs)"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
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
        case 204:
            return
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

    /// Sets the volume for the current device
    static func setVolume(accessToken: String, volumePercent: Int, deviceId: String? = nil) async throws {
        var urlString = "\(baseURL)/me/player/volume?volume_percent=\(volumePercent)"
        if let deviceId {
            urlString += "&device_id=\(deviceId)"
        }
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
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
        case 204:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Volume control not available for this device")
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

    // MARK: - Playback State

    /// Fetches the current playback state
    static func fetchPlaybackState(accessToken: String) async throws -> PlaybackState? {
        let urlString = "\(baseURL)/me/player"
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyAPIError.invalidResponse
            }

            let isPlaying = json["is_playing"] as? Bool ?? false
            let progressMs = json["progress_ms"] as? Int ?? 0
            let shuffleState = json["shuffle_state"] as? Bool ?? false
            let repeatState = json["repeat_state"] as? String ?? "off"

            var device: SpotifyDevice?
            if let deviceJson = json["device"] as? [String: Any],
               let deviceId = deviceJson["id"] as? String,
               let deviceName = deviceJson["name"] as? String,
               let deviceType = deviceJson["type"] as? String
            {
                device = SpotifyDevice(
                    id: deviceId,
                    isActive: deviceJson["is_active"] as? Bool ?? false,
                    isPrivateSession: deviceJson["is_private_session"] as? Bool ?? false,
                    isRestricted: deviceJson["is_restricted"] as? Bool ?? false,
                    name: deviceName,
                    type: deviceType,
                    volumePercent: deviceJson["volume_percent"] as? Int,
                )
            }

            var currentTrack: APITrack?
            if let item = json["item"] as? [String: Any] {
                currentTrack = parseTrackFromJSON(item)
            }

            return PlaybackState(
                currentTrack: currentTrack,
                device: device,
                isPlaying: isPlaying,
                progressMs: progressMs,
                repeatState: repeatState,
                shuffleState: shuffleState,
            )
        case 204:
            return nil
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

    /// Fetches the current playback queue
    static func fetchQueue(accessToken: String) async throws -> QueueResponse {
        let urlString = "\(baseURL)/me/player/queue"
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyAPIError.invalidResponse
            }

            let currentlyPlaying: APITrack? = (json["currently_playing"] as? [String: Any]).flatMap { parseTrackFromJSON($0) }
            let queueArray = json["queue"] as? [[String: Any]] ?? []
            let queue = queueArray.compactMap { parseTrackFromJSON($0) }

            return QueueResponse(currentlyPlaying: currentlyPlaying, queue: queue)
        case 204:
            return QueueResponse(currentlyPlaying: nil, queue: [])
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

    // MARK: - Helper

    /// Parses a track from JSON (used for playback state and queue)
    private static func parseTrackFromJSON(_ json: [String: Any]) -> APITrack? {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String,
              let durationMs = json["duration_ms"] as? Int
        else {
            return nil
        }

        let artistsArray = json["artists"] as? [[String: Any]]
        let artistName = artistsArray?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? "Unknown"
        let artistId = artistsArray?.first?["id"] as? String

        let albumData = json["album"] as? [String: Any]
        let albumName = albumData?["name"] as? String
        let albumId = albumData?["id"] as? String
        let albumImages = albumData?["images"] as? [[String: Any]]
        let imageURLString = albumImages?.first?["url"] as? String
        let imageURL = imageURLString.flatMap { URL(string: $0) }

        let externalUrls = json["external_urls"] as? [String: Any]
        let externalUrl = externalUrls?["spotify"] as? String

        return APITrack(
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
    }
}
