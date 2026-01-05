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
    /// The current access token - kept fresh by background refresh task
    private(set) var accessToken: String

    /// The refresh token (if available)
    private(set) var refreshToken: String?

    /// Token expiration time in seconds (from when token was obtained)
    private(set) var expiresIn: UInt64

    /// The current user's Spotify ID (loaded lazily)
    private(set) var userId: String?

    /// Whether we're currently loading the user ID
    private var isLoadingUserId = false

    /// Whether a token refresh is currently in progress
    private var isRefreshing = false

    /// Background task that proactively refreshes the token before expiration
    /// Marked nonisolated(unsafe) to allow cancellation in deinit
    private nonisolated(unsafe) var refreshTask: Task<Void, Never>?

    init(authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
        scheduleProactiveRefresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Update the session with new auth result (e.g., after token refresh)
    func update(with authResult: SpotifyAuthResult) {
        accessToken = authResult.accessToken
        refreshToken = authResult.refreshToken
        expiresIn = authResult.expiresIn
    }

    /// Schedules a background task to refresh the token before it expires
    private func scheduleProactiveRefresh() {
        refreshTask?.cancel()

        guard let refreshToken, expiresIn > 0 else { return }

        // Refresh 5 minutes before expiration (or halfway if token lifetime < 10 min)
        let refreshBuffer: TimeInterval = min(300, TimeInterval(expiresIn) / 2)
        let refreshDelay = TimeInterval(expiresIn) - refreshBuffer

        guard refreshDelay > 0 else {
            // Token already expired or about to - refresh immediately
            Task {
                await performRefresh(refreshToken: refreshToken)
            }
            return
        }

        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(refreshDelay))
                guard !Task.isCancelled else { return }
                await self?.performRefresh(refreshToken: refreshToken)
            } catch {
                // Task was cancelled
            }
        }

        #if DEBUG
            let refreshTime = Date().addingTimeInterval(refreshDelay)
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            print("[SpotifySession] Token refresh scheduled for \(formatter.string(from: refreshTime))")
        #endif
    }

    /// Performs the token refresh and schedules the next one
    private func performRefresh(refreshToken: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newResult = try await SpotifyAuth.refreshAccessToken(refreshToken: refreshToken)
            update(with: newResult)
            try? KeychainManager.saveAuthResult(newResult)
            #if DEBUG
                print("[SpotifySession] Token refreshed successfully")
            #endif
            scheduleProactiveRefresh()
        } catch {
            #if DEBUG
                print("[SpotifySession] Token refresh failed: \(error), retrying in 1 minute")
            #endif
            // Retry in 1 minute
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.performRefresh(refreshToken: refreshToken)
            }
        }
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
