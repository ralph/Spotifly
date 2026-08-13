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
    /// - Parameter expectedAccountId: the Spotify account the app is signed in as, when the
    ///   caller knows it. Callers inside the app read it from the store; the login step runs
    ///   before any store exists and passes nil, which falls back to one lookup.
    func authorizeStreaming(expectedAccountId: String? = nil) async {
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
            let mismatch = await streamingAccountMismatch(expectedAccountId: expectedAccountId)

            guard startedAt == authLifecycle else {
                // Logged out while this was deciding, and this run has to undo its own
                // writes rather than just walk away. Rust used to notice a logout itself,
                // because it held the browser wait and snapshotted the generation before it;
                // now Swift runs the browser half, so Rust's snapshot is taken *after* the
                // logout and its own supersession check passes. Whatever this grant wrote —
                // the AP credentials and the keymaster tokens — belongs to an account that
                // is gone, and logout cleared the cache before either was written.
                debugLog("AuthViewModel", "Streaming grant abandoned: logged out mid-flight")
                await PlaybackViewModel.shared.shutdownForLogout()
                await SpotifyPlayer.clearStreamingCredentials()
                hasStreamingCredentials = false
                return
            }

            if let mismatch {
                debugLog("AuthViewModel", "Streaming grant rejected: \(mismatch)")
                // A play or retry may have initialized the player from the cached
                // credentials while the comparison was in flight, so there can be a live
                // session for the wrong account. Removing the directory would leave it
                // connected and able to write its credentials back.
                // Through the playback lifecycle, not straight to Rust: tearing the
                // session down behind PlaybackViewModel leaves `isInitialized` true — the
                // connection subscription deliberately does not clear it on a disconnect —
                // so the app would hide the re-authorization affordance and keep aiming
                // plays at a player that no longer exists.
                await PlaybackViewModel.shared.shutdownForLogout()
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
    /// Pure, so the rule is testable and so the common path performs no I/O at all: callers
    /// inside the app already know who is signed in.
    static func accountMismatch(expected: String?, granted: String?) -> String? {
        guard let expected, let granted, expected != granted else { return nil }
        return "streaming account \(granted) is not the signed-in account \(expected)"
    }

    /// Resolves both accounts and compares them.
    ///
    /// Not knowing either one counts as agreement. Refusing a grant because an identity was
    /// briefly unavailable would be worse than the case being guarded against, which needs
    /// the user to have deliberately signed the browser into a second account.
    private func streamingAccountMismatch(expectedAccountId: String?) async -> String? {
        let granted = SpotifyPlayer.lastGrantAccountId()

        if let expectedAccountId {
            return Self.accountMismatch(expected: expectedAccountId, granted: granted)
        }

        // Only the login step reaches here, before a store exists to ask. Its token was
        // minted moments ago by step 1, so this needs no refresh — which matters, because a
        // refresh persists to the keychain and a logout crossing it would restore the
        // credentials logout had just cleared.
        guard let token = authResult?.accessToken,
              let profile = try? await SpotifyAPI.getCurrentUserProfile(accessToken: token)
        else {
            return nil
        }

        return Self.accountMismatch(expected: profile.id, granted: granted)
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
