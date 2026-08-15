//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify URI parsing. No longer a client of anything.
//

import Foundation

/// What is left of the Web API client: no base url, no requests, no errors — the last four
/// calls moved to the playlist service on 2026-08-14. The name is kept for now because its one
/// remaining member is spelled `SpotifyAPI.parseTrackURI` at every call site; retiring it belongs
/// with the rest of the dashboard-app cleanup.
enum SpotifyAPI {
    /// The track id in a `spotify:track:…` uri or an `open.spotify.com/track/…` link.
    static func parseTrackURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        guard let range = trimmed.range(of: "open.spotify.com/track/") else { return nil }
        // Everything up to the query string, which carries `?si=` share tokens.
        let id = trimmed[range.upperBound...].prefix { $0 != "?" }
        return id.isEmpty ? nil : String(id)
    }
}
