//
//  AuthViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import Combine
import SwiftUI

@MainActor
@Observable
final class AuthViewModel {
    /// Whether this Mac holds a grant — which is the whole of being signed in now.
    ///
    /// There used to be two: a dashboard OAuth that gated the app, and a streaming grant that
    /// gated playback. One authorization writes both halves of what is left, so this is read
    /// from `KeymasterSession`, the half every request needs. librespot's own credentials file
    /// is the *other* half, and it is deliberately not consulted here: a grant whose accesspoint
    /// connect failed still browses, and the app already has a way to offer playback again.
    var isSignedIn = false
    var errorMessage: String?
    var isLoading = true

    /// Runs the one grant the app has. Named for what it enables rather than for signing in,
    /// because it is reachable from three places — this screen, the Speakers row and the play
    /// alert — and only the first of them is a login.
    var isAuthorizingStreaming = false
    /// The grant in flight, held so it can be cancelled. Not observed by any view.
    @ObservationIgnored private var streamingAuthorization: Task<Void, Never>?

    /// Names the run that owns `streamingAuthorization`, so a run that has been abandoned
    /// cannot release a handle belonging to the one that replaced it.
    private var authorizationRun: UInt64 = 0

    /// Held for the life of the view model, which is the life of the app.
    @ObservationIgnored private var revocationSubscription: AnyCancellable?

    /// Bumped by logout. The grant spans a browser round-trip, so it can resume into a session
    /// that no longer exists; comparing this across the awaits is what stops it writing there.
    private var authLifecycle: UInt64 = 0

    init() {
        loadFromKeychain()

        // A grant Spotify has refused cannot be retried into working, and `KeymasterSession`
        // has already forgotten it by the time this fires. What is left is the rest of logging
        // out — the Spirc session still registered for that account, librespot's credentials
        // file, the login screen — and that is exactly what a deliberate logout does, so it
        // runs the same path rather than a second one that could drift from it.
        // `receive(on:)` is load-bearing rather than tidy: the announcement is sent from
        // `KeymasterSession`'s own executor, and this closure is main-actor isolated like
        // everything else in the app target. Delivered as-is it runs a MainActor closure on a
        // cooperative thread, which traps — on exactly the path this subscription exists for.
        revocationSubscription = KeymasterSession.shared.grantRevoked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                debugLog("AuthViewModel", "Grant revoked — signing out")
                Task { await self?.logout() }
            }
    }

    func loadFromKeychain() {
        isLoading = true
        Task {
            isSignedIn = await KeymasterSession.shared.hasGrant
            isLoading = false
        }
    }

    /// Runs the app's grant: the sign-in on the login screen, and the way back to being a
    /// playback device everywhere else.
    ///
    /// Blocks on the user finishing an authorization in their browser, so it can take a
    /// while; `isAuthorizingStreaming` drives the progress the UI shows meanwhile.
    /// - Parameter expectedAccountId: the Spotify account the app is signed in as, when the
    ///   caller knows it. Callers inside the app read it from the store; the login screen has
    ///   no store to read and passes nil, which is a sign-in rather than a change of account.
    func authorizeStreaming(expectedAccountId: String? = nil) async {
        isAuthorizingStreaming = true
        defer { isAuthorizingStreaming = false }

        errorMessage = nil

        // This runs across a browser round-trip that a logout can outlive. A superseded run
        // must not write (see AGENTS.md): resuming afterwards would sign the app back in and
        // rebuild a player for an account that is gone.
        let startedAt = authLifecycle

        switch await SpotifyPlayer.authorizeStreaming() {
        case .authorized:
            // The browser runs the grant with whatever account it is signed into, which need
            // not be the one already signed in here. Accepting a mismatch would swap the
            // account under a library, a queue and a now-playing bar that go on showing the
            // previous one — with no visible sign of it.
            let mismatch = Self.accountMismatch(
                expected: expectedAccountId,
                granted: SpotifyPlayer.lastGrantAccountId(),
            )

            guard startedAt == authLifecycle else {
                // Logged out while this was deciding, and this run has to undo its own
                // writes rather than just walk away. The Rust path this replaced noticed a
                // logout itself, because it held the browser wait and snapshotted its
                // generation before it; Swift runs the browser half now, so the client's
                // snapshot is taken *after* the logout and its own supersession check
                // passes. Whatever this grant wrote —
                // the AP credentials and the keymaster tokens — belongs to an account that
                // is gone, and logout cleared the cache before either was written.
                debugLog("AuthViewModel", "Streaming grant abandoned: logged out mid-flight")
                await discardGrant()
                return
            }

            if let mismatch {
                debugLog("AuthViewModel", "Streaming grant rejected: \(mismatch)")
                // A play or retry may have initialized the player from the cached
                // credentials while the comparison was in flight, so there can be a live
                // session for the wrong account.
                //
                // A mismatch caught at sign-in cannot arise — there is nothing to mismatch
                // against — so this only ever refuses a *change* of account, and the previous
                // grant it declined to replace is the one that just went with the clear.
                await discardGrant()
                errorMessage = String(localized: "auth.enable_playback_wrong_account")
                return
            }

            isSignedIn = true
            // Build the session now rather than waiting for the next play. The grant only
            // wrote credentials to disk; until something connects with them this Mac is
            // still not registered with Spotify Connect, so it would stay missing from
            // Speakers and the next play would raise the alert all over again.
            await PlaybackViewModel.shared.forceReinitialize()
        case .superseded:
            // A logout won the race and the credentials were removed again. Nothing went
            // wrong and there is nothing to report.
            break
        case .cancelled:
            // The user closed the browser tab or pressed Cancel. They asked for this, so
            // there is nothing to report.
            break
        case .failed:
            // The two halves fail independently, and only one of them is the sign-in: the
            // token is adopted *before* librespot connects, so a failure here can still leave
            // a usable grant behind. Read what survived rather than assuming — an app that
            // browses but cannot play is the honest outcome, and Speakers and the play alert
            // both offer the connect again.
            isSignedIn = await KeymasterSession.shared.hasGrant
            errorMessage = String(localized: "auth.connect_failed")
        }
    }

    /// Starts the grant and keeps hold of it, so it can be abandoned.
    ///
    /// The task lives here rather than in the view because the view that started it can be
    /// torn down — switching away from Speakers, or the login step giving way to the app —
    /// while the browser round-trip is still outstanding.
    func startStreamingAuthorization(expectedAccountId: String? = nil) {
        guard streamingAuthorization == nil else { return }

        authorizationRun &+= 1
        let run = authorizationRun
        streamingAuthorization = Task { [weak self] in
            await self?.authorizeStreaming(expectedAccountId: expectedAccountId)
            self?.finishStreamingAuthorization(run)
        }
    }

    /// Releases the handle, but only if it is still this run's.
    ///
    /// `authorizeStreaming` clears `isAuthorizingStreaming` on its way out, which is what turns
    /// the button back into "Connect" — and the hop back to this task body is a window in which
    /// a press can start the next run. Releasing unconditionally there drops the *new* run's
    /// handle, leaving it uncancellable and letting a further press start a second grant beside
    /// it. Narrow, but it is the invariant the rest of the app already holds to.
    private func finishStreamingAuthorization(_ run: UInt64) {
        guard run == authorizationRun else { return }
        streamingAuthorization = nil
    }

    /// Abandons a grant waiting on the browser.
    ///
    /// Only possible now that Swift owns the flow: librespot's listener had no timeout and
    /// no cancellation, so closing the browser tab left the enable affordance spinning with
    /// no way back to it.
    func cancelStreamingAuthorization() {
        streamingAuthorization?.cancel()
        streamingAuthorization = nil
    }

    /// Describes the mismatch between the account already signed in and the one the browser
    /// just granted, or nil when they agree.
    ///
    /// Pure, so the rule is testable and so the common path performs no I/O at all: callers
    /// inside the app already know who is signed in.
    ///
    /// Not knowing either account counts as agreement. Refusing a grant because an identity was
    /// briefly unavailable would be worse than the case being guarded against, which needs
    /// the user to have deliberately signed the browser into a second account.
    ///
    /// **This guard outlived its original reason.** It was written when two grants could
    /// disagree permanently — the app browsing account A on a dashboard token while playing
    /// account B on a streaming one — and there is one grant now, so that state cannot exist.
    /// What it still catches is the case that actually arises: re-authorizing from Speakers or
    /// the play alert while signed in, where the browser is signed into a different account.
    /// Replacing the grant there is not a partial failure but it is silent — the library, the
    /// queue and the now-playing bar go on showing the previous account until a relaunch — so
    /// it is still refused rather than accepted.
    ///
    /// Signing in has nothing to compare against and passes nil, which is agreement by the
    /// rule above. That is not a gap: at that point the granted account *is* the account.
    static func accountMismatch(expected: String?, granted: String?) -> String? {
        guard let expected, let granted, expected != granted else { return nil }
        return "streaming account \(granted) is not the signed-in account \(expected)"
    }

    /// Gives up the grant: tears the librespot session down, removes both credentials, and
    /// leaves the app signed out. The whole of logging out, and of undoing a grant that must
    /// not stand.
    ///
    /// The teardown comes first, and is awaited. Without it the Spirc connection stayed
    /// registered on Spotify Connect for the account that just logged out — and because
    /// nothing set the shutdown flag, the recovery loop treated the next network hiccup as an
    /// outage worth fixing and re-announced the device. The flag is raised before Spirc is
    /// touched, so recovery stops even when the goodbye itself cannot go out — logging out
    /// mid-outage is exactly when that matters — and is cleared again by
    /// `LibrespotClient.initialize`. It goes through the playback lifecycle rather than
    /// straight to the client: tearing the session down behind `PlaybackViewModel` leaves
    /// `isInitialized` true,
    /// since the connection subscription deliberately does not clear it on a disconnect, so
    /// the app would hide the re-authorization affordance and keep aiming plays at a player
    /// that no longer exists.
    ///
    /// Only then are the credentials removed — the keymaster tokens in the keychain and
    /// librespot's AP credentials, which are a file and would otherwise let the next launch
    /// connect the account that just logged out. After the teardown, so no live session can
    /// write them back.
    private func discardGrant() async {
        await PlaybackViewModel.shared.shutdownForLogout()
        await SpotifyPlayer.clearStreamingCredentials()
        isSignedIn = false
    }

    func logout() async {
        // Invalidates any streaming grant still deciding, so it cannot resume into the
        // session this is tearing down.
        authLifecycle &+= 1

        await discardGrant()
    }
}
