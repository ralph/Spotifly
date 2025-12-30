//
//  SpotifyConfig.swift
//  Spotifly
//
//  Configuration for Spotify API credentials
//
//  To get your own credentials:
//  1. Go to https://developer.spotify.com/dashboard
//  2. Create a new app
//  3. Add "http://127.0.0.1:8888/login" as a Redirect URI in the app settings
//  4. Set environment variables in Xcode:
//     - Edit Scheme > Run > Arguments > Environment Variables
//     - Add: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_REDIRECT_URI
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
    /// Your Spotify App Client ID (from SPOTIFY_CLIENT_ID environment variable)
    nonisolated static let clientId: String = {
        guard let value = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] else {
            fatalError("Missing required environment variable: SPOTIFY_CLIENT_ID")
        }
        return value
    }()

    /// Your Spotify App Client Secret (from SPOTIFY_CLIENT_SECRET environment variable)
    nonisolated static let clientSecret: String = {
        guard let value = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] else {
            fatalError("Missing required environment variable: SPOTIFY_CLIENT_SECRET")
        }
        return value
    }()

    /// Redirect URI (from SPOTIFY_REDIRECT_URI environment variable)
    nonisolated static let redirectUri: String = {
        guard let value = ProcessInfo.processInfo.environment["SPOTIFY_REDIRECT_URI"] else {
            fatalError("Missing required environment variable: SPOTIFY_REDIRECT_URI")
        }
        return value
    }()
}
