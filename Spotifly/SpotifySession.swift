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

    /// Token expiration time in seconds (from when token was obtained)
    private(set) var expiresIn: UInt64

    /// When the current token was obtained
    private var tokenObtainedAt: Date

    /// The current user's Spotify ID (loaded lazily)
    private(set) var userId: String?

    /// Whether we're currently loading the user ID
    private var isLoadingUserId = false

    /// Whether a token refresh is currently in progress
    private var isRefreshing = false

    /// Continuation for callers waiting on a refresh in progress
    private var refreshWaiters: [CheckedContinuation<String, Never>] = []

    init(authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
        tokenObtainedAt = Date()
    }

    /// Update the session with new auth result (e.g., after token refresh)
    func update(with authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
        tokenObtainedAt = Date()
    }

    /// Returns a valid access token, refreshing if necessary.
    /// This is sleep-proof: validation happens at access time, not on a scheduled timer.
    func validAccessToken() async -> String {
        let expirationDate = tokenObtainedAt.addingTimeInterval(TimeInterval(expiresIn))
        let bufferDate = Date().addingTimeInterval(300) // 5 min buffer

        if bufferDate < expirationDate {
            // Token still valid for 5+ minutes
            return accessToken
        }

        // Token expired or expiring soon - need to refresh
        guard let refreshToken else {
            // No refresh token available, return current token and hope for the best
            #if DEBUG
                print("[SpotifySession] Token expiring but no refresh token available")
            #endif
            return accessToken
        }

        // If already refreshing, wait for that to complete
        if isRefreshing {
            return await withCheckedContinuation { continuation in
                refreshWaiters.append(continuation)
            }
        }

        // Perform the refresh
        return await performRefreshAndReturn(refreshToken: refreshToken)
    }

    /// Performs the token refresh and returns the new token
    private func performRefreshAndReturn(refreshToken: String) async -> String {
        isRefreshing = true

        do {
            let useCustomClientId = KeychainManager.loadUseCustomClientId()
            let newResult = try await SpotifyAuth.refreshAccessToken(refreshToken: refreshToken, useCustomClientId: useCustomClientId)
            update(with: newResult)
            try? KeychainManager.saveAuthResult(newResult)
            #if DEBUG
                print("[SpotifySession] Token refreshed successfully")
            #endif

            // Resume all waiters with new token
            let token = accessToken
            for waiter in refreshWaiters {
                waiter.resume(returning: token)
            }
            refreshWaiters.removeAll()
            isRefreshing = false

            return token
        } catch {
            #if DEBUG
                print("[SpotifySession] Token refresh failed: \(error)")
            #endif

            // Resume waiters with current token (may be expired)
            let token = accessToken
            for waiter in refreshWaiters {
                waiter.resume(returning: token)
            }
            refreshWaiters.removeAll()
            isRefreshing = false

            return token
        }
    }

    /// Loads the current user's ID if not already loaded
    func loadUserIdIfNeeded() async {
        guard userId == nil, !isLoadingUserId else { return }
        isLoadingUserId = true
        do {
            let token = await validAccessToken()
            userId = try await SpotifyAPI.getCurrentUserId(accessToken: token)
        } catch {
            // Silently fail - userId will remain nil
        }
        isLoadingUserId = false
    }
}
