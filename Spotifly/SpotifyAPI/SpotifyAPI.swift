//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify Web API client - base definitions and utilities.
//

import Foundation
import os.log

let apiLogger = Logger(subsystem: "com.spotifly.app", category: "SpotifyAPI")

/// Spotify Web API client
enum SpotifyAPI {
    static let baseURL = "https://api.spotify.com/v1"

    /// Helper to throw appropriate error from API error response data
    static func throwAPIError(data: Data, statusCode: Int) throws -> Never {
        if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
            throw SpotifyAPIError.apiError(errorResponse.error.message)
        }
        throw SpotifyAPIError.apiError("HTTP \(statusCode)")
    }

    /// Parses a Spotify URI (spotify:track:xxx) and returns the track ID
    static func parseTrackURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle spotify:track:ID format
        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        // Handle open.spotify.com/track/ID format
        if trimmed.contains("open.spotify.com/track/") {
            if let range = trimmed.range(of: "open.spotify.com/track/") {
                var trackId = String(trimmed[range.upperBound...])
                // Remove query parameters if present
                if let queryIndex = trackId.firstIndex(of: "?") {
                    trackId = String(trackId[..<queryIndex])
                }
                return trackId.isEmpty ? nil : trackId
            }
        }

        return nil
    }
}
