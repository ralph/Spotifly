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
    /// gated playback. One authorization is left, read from `KeymasterSession`, which every
    /// request needs.
    ///
    /// Signed in, the account's session starts (`startSession`). Signed out, whatever the way,
    /// it ends: the logout, a grant found revoked, and a launch that finds no grant.
    var isSignedIn = false {
        didSet {
            if isSignedIn {
                startSession()
            } else {
                sessions.end()
            }
        }
    }

    /// The signed-in account's store and services, which outlive a window. Here because their
    /// lifetime is the sign-in's, and this view model, like them, is the app's.
    let sessions = LoggedInSessions()

    /// Starts the account's session and hands it to playback at once: the queue service follows
    /// the player, `PlaybackViewModel` reads the track's metadata and the favorite toggle through
    /// it, and the player connects, so the devices and what they play are there without waiting
    /// for a window or the requests a window makes.
    ///
    /// Here, as the account signs in, rather than in the first window's task, which ran after
    /// its first frame, and so after the connect a sign-in starts: a report arriving in between
    /// was not hydrated. Not where the session is read, in `ContentView`'s body, which must not
    /// change state.
    private func startSession() {
        guard sessions.current == nil else { return }
        let session = sessions.start()
        PlaybackViewModel.shared.attach(store: session.store, trackService: session.trackService)
        Task { await PlaybackViewModel.shared.initializeIfNeeded() }
    }

    /// Why the last grant did not take: on the login screen while signed out, and as an alert
    /// in the signed-in app.
    var errorMessage: String?
    var isLoading = true

    /// Whether the sign-in's grant is in flight, waiting on the browser; the login screen shows
    /// progress and offers Cancel meanwhile.
    var isAuthorizing = false
    /// The grant in flight, held so it can be cancelled. Not observed by any view.
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?

    /// Names the run that owns `authorizationTask`, so a run that has been abandoned
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
        // out — the Spirc session still registered for that account, the keymaster tokens,
        // the login screen — and that is exactly what a deliberate logout does, so it
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

    /// Runs the app's grant: the sign-in on the login screen.
    ///
    /// Blocks on the user finishing an authorization in their browser, so it can take a
    /// while; `isAuthorizing` drives the progress the UI shows meanwhile.
    func authorize() async {
        isAuthorizing = true
        defer { isAuthorizing = false }

        errorMessage = nil

        // This runs across a browser round-trip that a logout can outlive. A superseded run
        // must not write (see AGENTS.md): resuming afterwards would sign the app back in and
        // rebuild a player for an account that is gone.
        let startedAt = authLifecycle

        // Minted in the browser, and written only once it is known to be wanted: a grant
        // refused here leaves the one it was to replace as it was, signed in.
        let tokens: KeymasterTokens
        do {
            tokens = try await KeymasterAuth.authorize()
        } catch where isCancellation(error) {
            // The user closed the browser tab or pressed Cancel, during the browser wait or the
            // token exchange after it. They asked for this, so there is nothing to report.
            debugLog("AuthViewModel", "Authorization cancelled")
            return
        } catch {
            debugLog("AuthViewModel", "Authorization failed: \(error)")
            errorMessage = String(localized: "auth.connect_failed")
            return
        }

        // Logged out while the browser had the grant: nothing was written, and nothing is.
        guard startedAt == authLifecycle else {
            debugLog("AuthViewModel", "Grant abandoned: logged out mid-flight")
            return
        }

        do {
            try await KeymasterSession.shared.adopt(tokens)
        } catch let KeymasterSessionError.otherAccount(held, granted) {
            // Only a grant still held refuses another account's, and signed out there is none.
            debugLog("AuthViewModel", "Grant rejected: account \(granted) is not the signed-in account \(held)")
            errorMessage = String(localized: "auth.connect_failed")
            return
        } catch {
            // The keychain refused the tokens, which `KeymasterSession` holds for this launch
            // all the same.
            debugLog("AuthViewModel", "Grant not saved: \(error)")
            isSignedIn = await KeymasterSession.shared.hasGrant
            errorMessage = String(localized: "auth.connect_failed")
            return
        }

        // A logout that landed while the tokens were written cleared the keychain before or
        // after them; this run undoes its own write either way.
        guard startedAt == authLifecycle else {
            debugLog("AuthViewModel", "Grant abandoned: logged out while it was saved")
            await KeymasterSession.shared.clear()
            return
        }

        // The session connects as it starts (`startSession`).
        isSignedIn = true
    }

    /// Starts the grant and keeps hold of it, so it can be abandoned.
    ///
    /// The task lives here rather than in the view because the view that started it can be
    /// torn down — the login step giving way to the app — while the browser round-trip is
    /// still outstanding.
    func startAuthorization() {
        guard authorizationTask == nil else { return }

        authorizationRun &+= 1
        let run = authorizationRun
        authorizationTask = Task { [weak self] in
            await self?.authorize()
            self?.finishAuthorization(run)
        }
    }

    /// Releases the handle, but only if it is still this run's.
    ///
    /// `authorize` clears `isAuthorizing` on its way out, which is what turns
    /// the button back into "Connect" — and the hop back to this task body is a window in which
    /// a press can start the next run. Releasing unconditionally there drops the *new* run's
    /// handle, leaving it uncancellable and letting a further press start a second grant beside
    /// it. Narrow, but it is the invariant the rest of the app already holds to.
    private func finishAuthorization(_ run: UInt64) {
        guard run == authorizationRun else { return }
        authorizationTask = nil
    }

    /// Abandons a grant waiting on the browser.
    ///
    /// Only possible now that Swift owns the flow: librespot's listener had no timeout and
    /// no cancellation, so closing the browser tab left the enable affordance spinning with
    /// no way back to it.
    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
    }

    /// Logs out: tears the librespot session down, removes both credentials, and leaves the
    /// app signed out. Also what a revoked grant does.
    ///
    /// The teardown comes first, and is awaited. Without it the Spirc connection stayed
    /// registered on Spotify Connect for the account that just logged out — and because
    /// nothing set the shutdown flag, the recovery loop treated the next network hiccup as an
    /// outage worth fixing and re-announced the device. The flag is raised before Spirc is
    /// touched, so recovery stops even when Spotify cannot be reached — logging out
    /// mid-outage is exactly when that matters — and is cleared again by
    /// `LibrespotClient.initialize`. It goes through the playback lifecycle rather than
    /// straight to the client: tearing the session down behind `PlaybackViewModel` leaves
    /// `isInitialized` true, since the connection subscription deliberately does not clear it
    /// on a disconnect, so the app would keep aiming plays at a session that no longer exists.
    ///
    /// Only then are the credentials removed — the session's, and the keymaster tokens in the
    /// keychain, which would otherwise let the next launch connect the account that just logged
    /// out. After the teardown, so no live session can use them again.
    func logout() async {
        // Invalidates any grant still in flight, so it cannot resume into the
        // session this is tearing down.
        authLifecycle &+= 1
        // A grant's refusal belongs to the session it was refused in, not to the login screen.
        errorMessage = nil

        await PlaybackViewModel.shared.shutdownForLogout()
        await SpotifyPlayer.clearStreamingCredentials()
        isSignedIn = false
    }
}
