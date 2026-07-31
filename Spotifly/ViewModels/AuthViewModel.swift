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

        SpotifyAuth.clearAuthResult()
        KeychainManager.clearAuthResult()
        authResult = nil
    }
}
