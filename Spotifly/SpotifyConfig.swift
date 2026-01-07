//
//  SpotifyConfig.swift
//  Spotifly
//
//  Configuration for Spotify API credentials
//
//  To get your own credentials:
//  1. Go to https://developer.spotify.com/dashboard
//  2. Create a new app
//  3. Add "de.rvdh.spotifly://callback" as a Redirect URI in the app settings
//  4. Add your Client ID to Info.plist with key "SpotifyClientID"
//     OR set environment variable in Xcode for development:
//     - Edit Scheme > Run > Arguments > Environment Variables
//     - Add: SPOTIFY_CLIENT_ID
//

import Foundation

enum SpotifyConfigError: Error, LocalizedError {
    case missingEnvironmentVariable(String)

    var errorDescription: String? {
        switch self {
        case let .missingEnvironmentVariable(name):
            "Missing required environment variable: \(name). Set it in Xcode: Edit Scheme > Run > Arguments > Environment Variables"
        }
    }
}

enum SpotifyConfig: Sendable {
    /// Built-in Spotify App Client ID (from Info.plist or SPOTIFY_CLIENT_ID environment variable)
    private nonisolated static let builtInClientId: String = {
        // First try to read from Info.plist (for release builds)
        if let infoPlistValue = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
           !infoPlistValue.isEmpty
        {
            return infoPlistValue
        }

        // Fall back to environment variable (for development)
        if let envValue = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] {
            return envValue
        }

        fatalError("Missing Spotify Client ID. Add SpotifyClientID to Info.plist or set SPOTIFY_CLIENT_ID environment variable.")
    }()

    /// Returns the active Client ID: custom from keychain if available, otherwise built-in
    nonisolated static func getClientId() -> String {
        if let customClientId = KeychainManager.loadCustomClientId(), !customClientId.isEmpty {
            return customClientId
        }
        return builtInClientId
    }

    /// Redirect URI for OAuth callback
    nonisolated static let redirectUri = "de.rvdh.spotifly://callback"

    /// URL scheme for the callback (extracted from redirectUri)
    nonisolated static let callbackURLScheme = "de.rvdh.spotifly"

    /// OAuth scopes required by the app
    nonisolated static let scopes: [String] = [
        "user-read-private",
        "user-read-email",
        "streaming",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-public",
        "playlist-modify-private",
        "user-library-read",
        "user-library-modify",
        "user-follow-read",
        "user-read-recently-played",
    ]
}
