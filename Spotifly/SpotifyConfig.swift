//
//  SpotifyConfig.swift
//  Spotifly
//
//  Configuration for Spotify API credentials
//
//  Users must provide their own Spotify Client ID.
//  See: https://github.com/ralph/homebrew-spotifly?tab=readme-ov-file#using-your-own-client-id
//

import Foundation

enum SpotifyConfigError: Error, LocalizedError {
    case missingClientId

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            "Missing Spotify Client ID. Please enter your Client ID on the login screen."
        }
    }
}

enum SpotifyConfig: Sendable {
    /// Returns the Client ID from keychain
    /// - Returns: The stored Client ID, or crashes if not set (should be set before login)
    nonisolated static func getClientId() -> String {
        guard let clientId = KeychainManager.loadCustomClientId(), !clientId.isEmpty else {
            fatalError("Missing Spotify Client ID. Please enter your Client ID on the login screen.")
        }
        return clientId
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
