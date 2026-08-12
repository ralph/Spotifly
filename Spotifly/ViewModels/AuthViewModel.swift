//
//  AuthViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class AuthViewModel {
    var isAuthenticating = false
    var authResult: SpotifyAuthResult?
    var errorMessage: String?
    var isLoading = true

    /// The streaming grant runs separately from the Web API login and uses a different
    /// client id, because Spotify allows neither id to do the other's job. Skipping it is
    /// fine: the app browses and drives other devices, it just is not a Connect device
    /// itself. See `plans/streaming-auth-needs-a-first-party-client-id.md`.
    var isAuthorizingStreaming = false
    var hasStreamingCredentials = SpotifyPlayer.hasCachedStreamingCredentials()

    init() {
        // Try to load existing auth from keychain on init
        loadFromKeychain()
    }

    func loadFromKeychain() {
        isLoading = true
        Task {
            // Attempt to load and refresh if needed
            if let savedResult = await KeychainManager.loadAuthResultWithRefresh() {
                await MainActor.run {
                    self.authResult = savedResult
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    /// Runs the streaming grant and records whether this Mac can be a playback device.
    ///
    /// Blocks on the user finishing an authorization in their browser, so it can take a
    /// while; `isAuthorizingStreaming` drives the progress the UI shows meanwhile.
    func authorizeStreaming() async {
        isAuthorizingStreaming = true
        defer { isAuthorizingStreaming = false }

        errorMessage = nil

        switch await SpotifyPlayer.authorizeStreaming() {
        case .authorized:
            hasStreamingCredentials = true
            // Build the session now rather than waiting for the next play. The grant only
            // wrote credentials to disk; until something connects with them this Mac is
            // still not registered with Spotify Connect, so it would stay missing from
            // Speakers and the next play would raise the alert all over again.
            await PlaybackViewModel.shared.forceReinitialize()
        case .superseded:
            // A logout won the race and the credentials were removed again. Nothing went
            // wrong and there is nothing to report.
            break
        case .failed:
            errorMessage = String(localized: "auth.enable_playback_failed")
        }
    }

    func startOAuth() {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                let result = try await SpotifyAuth.authenticate()
                self.authResult = result
                self.isAuthenticating = false

                // Save to keychain
                do {
                    try KeychainManager.saveAuthResult(result)
                } catch {
                    #if DEBUG
                        print("Failed to save to keychain: \(error)")
                    #endif
                }
            } catch {
                self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                self.isAuthenticating = false
            }
        }
    }

    func logout() async {
        // Tear the librespot session down, not just the Swift-side token. Without this the
        // Spirc connection stayed registered on Spotify Connect for the account that just
        // logged out — and because nothing set the shutdown flag, the recovery loop treated
        // the next network hiccup as an outage worth fixing and re-announced the device.
        // Clearing state alone deferred the teardown to the next login, which runs
        // `spotifly_cleanup()` before building a session.
        //
        // The teardown flag is raised before Spirc is touched, so recovery stops even when
        // the goodbye itself cannot go out — logging out mid-outage is exactly when this
        // matters. The flag is cleared again by `spotifly_init_player`.
        //
        // Awaited before the auth state is cleared so the login screen cannot come back and
        // start a new session while this one is still going down. Rust only hands Spirc a
        // command, so there is nothing slow to wait for.
        await PlaybackViewModel.shared.shutdownForLogout()

        // The streaming credentials are a file, not a keychain item, so clearing the
        // keychain does not touch them — left behind, they would let the next launch
        // connect the account that just logged out. Removed after the teardown, so no live
        // session can write them back.
        await SpotifyPlayer.clearStreamingCredentials()
        hasStreamingCredentials = false

        SpotifyAuth.clearAuthResult()
        KeychainManager.clearAuthResult()
        authResult = nil
    }
}
