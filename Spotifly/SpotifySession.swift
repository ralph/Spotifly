//
//  SpotifySession.swift
//  Spotifly
//
//  Centralized session management for Spotify authentication.
//  Provides access token to views and view models via environment.
//

import SwiftUI

/// Observable session that provides access to the Spotify access token.
/// Inject this into the environment to avoid passing authResult through every view.
@MainActor
@Observable
final class SpotifySession {
    /// The current access token
    private(set) var accessToken: String

    /// The refresh token (if available)
    private(set) var refreshToken: String?

    /// Token expiration time
    private(set) var expiresIn: UInt64

    /// The current user's Spotify ID (loaded lazily)
    private(set) var userId: String?

    /// Whether we're currently loading the user ID
    private var isLoadingUserId = false

    init(authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
    }

    /// Update the session with new auth result (e.g., after token refresh)
    func update(with authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
    }

    /// Loads the current user's ID if not already loaded
    func loadUserIdIfNeeded() async {
        guard userId == nil, !isLoadingUserId else { return }
        isLoadingUserId = true
        do {
            userId = try await SpotifyAPI.getCurrentUserId(accessToken: accessToken)
        } catch {
            // Silently fail - userId will remain nil
        }
        isLoadingUserId = false
    }
}
