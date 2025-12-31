//
//  SpotifyAuth.swift
//  Spotifly
//
//  Swift wrapper for the Rust librespot OAuth functionality
//

import Foundation
import SpotiflyRust

/// Actor that manages Spotify OAuth authentication using librespot
@globalActor
actor SpotifyAuthActor {
    static let shared = SpotifyAuthActor()
}

/// Result of a successful OAuth flow
struct SpotifyAuthResult: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: UInt64
}

/// Errors that can occur during Spotify authentication
enum SpotifyAuthError: Error, Sendable {
    case authenticationFailed
    case noTokenAvailable
    case refreshFailed
}

/// Swift wrapper for the Rust librespot OAuth functionality
enum SpotifyAuth {
    /// Initiates the Spotify OAuth flow.
    /// This will open a browser window for the user to authenticate.
    /// - Returns: The authentication result containing tokens
    /// - Throws: SpotifyAuthError if authentication fails
    @SpotifyAuthActor
    static func authenticate() async throws -> SpotifyAuthResult {
        // Capture config values before entering detached task
        let clientId = SpotifyConfig.clientId
        let redirectUri = SpotifyConfig.redirectUri

        // Run the OAuth flow on a background thread since it blocks
        let result = await Task.detached {
            spotifly_start_oauth(clientId, redirectUri)
        }.value

        guard result == 0 else {
            throw SpotifyAuthError.authenticationFailed
        }

        guard spotifly_has_oauth_result() == 1 else {
            throw SpotifyAuthError.noTokenAvailable
        }

        // Get the access token
        guard let accessTokenPtr = spotifly_get_access_token() else {
            throw SpotifyAuthError.noTokenAvailable
        }
        let accessToken = String(cString: accessTokenPtr)
        spotifly_free_string(accessTokenPtr)

        // Get the refresh token (optional)
        var refreshToken: String? = nil
        if let refreshTokenPtr = spotifly_get_refresh_token() {
            refreshToken = String(cString: refreshTokenPtr)
            spotifly_free_string(refreshTokenPtr)
        }

        // Get expiration time
        let expiresIn = spotifly_get_token_expires_in()

        return SpotifyAuthResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
        )
    }

    /// Refreshes the access token using a refresh token.
    /// - Parameter refreshToken: The refresh token to use
    /// - Returns: The new authentication result containing fresh tokens
    /// - Throws: SpotifyAuthError if refresh fails
    @SpotifyAuthActor
    static func refreshAccessToken(refreshToken: String) async throws -> SpotifyAuthResult {
        // Capture config values before entering detached task
        let clientId = SpotifyConfig.clientId
        let redirectUri = SpotifyConfig.redirectUri

        // Run the token refresh on a background thread since it blocks
        let result = await Task.detached {
            spotifly_refresh_access_token(clientId, redirectUri, refreshToken)
        }.value

        guard result == 0 else {
            throw SpotifyAuthError.refreshFailed
        }

        guard spotifly_has_oauth_result() == 1 else {
            throw SpotifyAuthError.noTokenAvailable
        }

        // Get the new access token
        guard let accessTokenPtr = spotifly_get_access_token() else {
            throw SpotifyAuthError.noTokenAvailable
        }
        let accessToken = String(cString: accessTokenPtr)
        spotifly_free_string(accessTokenPtr)

        // Get the new refresh token (optional)
        var newRefreshToken: String? = nil
        if let refreshTokenPtr = spotifly_get_refresh_token() {
            newRefreshToken = String(cString: refreshTokenPtr)
            spotifly_free_string(refreshTokenPtr)
        }

        // Get expiration time
        let expiresIn = spotifly_get_token_expires_in()

        return SpotifyAuthResult(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn,
        )
    }

    /// Checks if an OAuth result is currently available
    static var hasAuthResult: Bool {
        spotifly_has_oauth_result() == 1
    }

    /// Clears any stored OAuth result
    static func clearAuthResult() {
        spotifly_clear_oauth_result()
    }
}
