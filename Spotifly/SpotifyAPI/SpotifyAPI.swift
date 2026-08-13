//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify URI and link helpers. No longer a client of anything.
//

import Foundation

/// Spotify item types for generating external URLs
enum SpotifyItemType: String {
    case track
    case album
    case artist
    case playlist
    case user
}

/// Generates a Spotify external URL from item type and ID
func spotifyExternalUrl(type: SpotifyItemType, id: String) -> String {
    "https://open.spotify.com/\(type.rawValue)/\(id)"
}

/// What is left of the Web API client: no base url, no requests, no errors — the last four
/// calls moved to the playlist service on 2026-08-14. The name is kept for now because its one
/// remaining member is spelled `SpotifyAPI.parseTrackURI` at six call sites; retiring it belongs
/// with the rest of the dashboard-app cleanup.
enum SpotifyAPI {
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
