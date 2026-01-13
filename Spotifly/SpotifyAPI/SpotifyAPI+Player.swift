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
            do {
                let decoded = try JSONDecoder().decode(DevicesCodable.self, from: data)
                let devices = decoded.devices.compactMap { $0.toSpotifyDevice() }
                return DevicesResponse(devices: devices)
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Playback Control

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
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
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
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Sets shuffle mode for playback
    static func setShuffle(accessToken: String, state: Bool) async throws {
        let urlString = "\(baseURL)/me/player/shuffle?state=\(state)"
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
        case 404:
            throw SpotifyAPIError.apiError("No active device found")
        default:
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Sets repeat mode for playback
    /// - Parameter state: "track" for repeat one, "context" for repeat all, "off" to disable
    static func setRepeatMode(accessToken: String, state: String) async throws {
        let urlString = "\(baseURL)/me/player/repeat?state=\(state)"
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
        case 404:
            throw SpotifyAPIError.apiError("No active device found")
        default:
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
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
            do {
                let decoded = try JSONDecoder().decode(PlaybackStateCodable.self, from: data)
                return decoded.toPlaybackState()
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 204:
            return nil
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    /// Adds a track to the playback queue via Spotify Web API.
    /// This goes through Spotify's servers and syncs with Spirc via dealer.
    /// - Parameters:
    ///   - trackUri: The Spotify track URI (e.g., "spotify:track:xxx")
    ///   - accessToken: The access token for authentication
    static func addToQueue(trackUri: String, accessToken: String) async throws {
        let urlString = "\(baseURL)/me/player/queue?uri=\(trackUri)"
        #if DEBUG
            apiLogger.debug("[POST] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return // Success - no content returned
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.apiError("No active device found. Start playback first.")
        default:
            if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
                throw SpotifyAPIError.apiError(errorResponse.error.message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
}
