//
//  SpotifyConfig.swift
//  Spotifly
//
//  Configuration for Spotify API credentials
//
//  Supports two authentication modes:
//  1. Keymaster auth (default): Uses official Spotify desktop client ID
//  2. Custom client ID auth: Uses user's own client ID from Spotify Developer Dashboard
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
    // MARK: - Keymaster Auth Configuration

    /// Keymaster client ID (official Spotify desktop app)
    /// This is a well-known public client ID used by the Spotify desktop application
    nonisolated static let keymasterClientId = "65b708073fc0480ea92a077233ca87bd"

    /// Redirect URI for keymaster auth (localhost, used by librespot-oauth)
    nonisolated static let keymasterRedirectUri = "http://127.0.0.1:8888/login"

    // MARK: - Custom Client ID Auth Configuration

    /// Redirect URI for custom client ID auth (custom URL scheme, used by ASWebAuthenticationSession)
    nonisolated static let customRedirectUri = "de.rvdh.spotifly://callback"

    /// URL scheme for the custom callback (extracted from customRedirectUri)
    nonisolated static let customCallbackURLScheme = "de.rvdh.spotifly"

    // MARK: - Helper Methods

    /// Returns the Client ID based on auth mode
    /// - Parameter useCustomClientId: Whether to use custom client ID mode
    /// - Returns: The appropriate client ID for the auth mode
    nonisolated static func getClientId(useCustomClientId: Bool) -> String {
        if useCustomClientId {
            guard let clientId = KeychainManager.loadCustomClientId(), !clientId.isEmpty else {
                fatalError("Custom client ID not set. Please enter your Client ID on the login screen.")
            }
            return clientId
        }
        return keymasterClientId
    }

    /// Returns the redirect URI based on auth mode
    /// - Parameter useCustomClientId: Whether to use custom client ID mode
    /// - Returns: The appropriate redirect URI for the auth mode
    nonisolated static func getRedirectUri(useCustomClientId: Bool) -> String {
        useCustomClientId ? customRedirectUri : keymasterRedirectUri
    }

    /// Legacy method for backward compatibility - returns keymaster client ID by default
    @available(*, deprecated, message: "Use getClientId(useCustomClientId:) instead")
    nonisolated static func getClientId() -> String {
        getClientId(useCustomClientId: KeychainManager.loadUseCustomClientId())
    }

    /// Legacy property for backward compatibility
    @available(*, deprecated, message: "Use customRedirectUri or keymasterRedirectUri instead")
    nonisolated static var redirectUri: String {
        getRedirectUri(useCustomClientId: KeychainManager.loadUseCustomClientId())
    }

    /// Legacy property for backward compatibility
    @available(*, deprecated, message: "Use customCallbackURLScheme instead")
    nonisolated static var callbackURLScheme: String {
        customCallbackURLScheme
    }

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
        "user-top-read",
    ]
}
