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

    /// Bumped by logout. The grant spans a browser round-trip and a `/me` lookup, so it can
    /// resume into a session that no longer exists; comparing this across the awaits is what
    /// stops it writing there.
    private var authLifecycle: UInt64 = 0

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

        // This runs across a browser round-trip and a `/me` lookup, either of which a logout
        // can outlive. A superseded run must not write (see AGENTS.md): resuming afterwards
        // would mark credentials present and rebuild a player for an account that is gone.
        let startedAt = authLifecycle

        switch await SpotifyPlayer.authorizeStreaming() {
        case .authorized:
            // The browser runs the grant with whatever account it is signed into, which is
            // not necessarily the one the Web API half uses. Accepting a mismatch would
            // leave the app browsing and editing account A while playing and queueing on
            // account B — with no visible sign of it.
            let mismatch = await streamingAccountMismatch()

            guard startedAt == authLifecycle else {
                // Logged out while this was deciding. Whatever the answer, it belongs to a
                // session that no longer exists, and logout has already cleared the cache.
                debugLog("AuthViewModel", "Streaming grant abandoned: logged out mid-flight")
                return
            }

            if let mismatch {
                debugLog("AuthViewModel", "Streaming grant rejected: \(mismatch)")
                // A play or retry may have initialized the player from the cached
                // credentials while the comparison was in flight, so there can be a live
                // session for the wrong account. Removing the directory would leave it
                // connected and able to write its credentials back.
                await SpotifyPlayer.shutdownAndCleanup()
                await SpotifyPlayer.clearStreamingCredentials()
                hasStreamingCredentials = false
                errorMessage = String(localized: "auth.enable_playback_wrong_account")
                return
            }

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

    /// Describes the account mismatch between the two grants, or nil when they agree.
    ///
    /// A failure to determine either side is treated as agreement: refusing a grant because
    /// `/me` happened to be unreachable would be worse than the case being guarded against,
    /// which needs the user to have deliberately signed the browser into another account.
    private func streamingAccountMismatch() async -> String? {
        guard let streamingAccount = SpotifyPlayer.lastGrantAccountId() else { return nil }

        // Not `authResult.accessToken`: that is the token minted at login, and `SpotifySession`
        // refreshes independently without writing back, so it is expired within the hour. An
        // expired token makes `/me` return 401, which this function reads as agreement — the
        // check would quietly stop working for exactly the mid-session case that Speakers
        // offers.
        guard let current = await KeychainManager.loadAuthResultWithRefresh(),
              let profile = try? await SpotifyAPI.getCurrentUserProfile(
                  accessToken: current.accessToken,
              )
        else {
            return nil
        }

        return profile.id == streamingAccount
            ? nil
            : "streaming account \(streamingAccount) is not the Web API account \(profile.id)"
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
        // Invalidates any streaming grant still deciding, so it cannot resume into the
        // session this is tearing down.
        authLifecycle &+= 1

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
