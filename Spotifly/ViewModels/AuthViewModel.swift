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

    /// Makes the account's session, unless there is one, and hands it to playback at once: the
    /// queue service follows the player, and `PlaybackViewModel` reads the track's metadata and
    /// the favorite toggle through it.
    ///
    /// Here, as the account signs in, rather than in the first window's task, which ran after
    /// its first frame, and so after the connect a sign-in starts: a report arriving in between
    /// was not hydrated. Not where the session is read, in `ContentView`'s body, which must not
    /// change state. Each step does nothing the second time, for a grant renewed while signed in.
    private func startSession() {
        let session = sessions.session()
        session.queueService.activate()
        PlaybackViewModel.shared.attach(store: session.store, trackService: session.trackService)
    }

    /// Why the last grant did not take: on the login screen while signed out, and as an alert
    /// in the signed-in app.
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
    func authorizeStreaming() async {
        isAuthorizingStreaming = true
        defer { isAuthorizingStreaming = false }

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
            debugLog("AuthViewModel", "Streaming authorization cancelled")
            return
        } catch {
            debugLog("AuthViewModel", "Streaming authorization failed: \(error)")
            errorMessage = String(localized: "auth.connect_failed")
            return
        }

        // Logged out while the browser had the grant: nothing was written, and nothing is.
        guard startedAt == authLifecycle else {
            debugLog("AuthViewModel", "Streaming grant abandoned: logged out mid-flight")
            return
        }

        do {
            try await KeymasterSession.shared.adopt(tokens)
        } catch let KeymasterSessionError.otherAccount(held, granted) {
            debugLog("AuthViewModel", "Streaming grant rejected: account \(granted) is not the signed-in account \(held)")
            errorMessage = String(localized: "auth.enable_playback_wrong_account")
            return
        } catch {
            // The keychain refused the tokens, which `KeymasterSession` holds for this launch
            // all the same.
            debugLog("AuthViewModel", "Streaming grant not saved: \(error)")
            isSignedIn = await KeymasterSession.shared.hasGrant
            errorMessage = String(localized: "auth.connect_failed")
            return
        }

        // A logout that landed while the tokens were written cleared the keychain before or
        // after them; this run undoes its own write either way.
        guard startedAt == authLifecycle else {
            debugLog("AuthViewModel", "Streaming grant abandoned: logged out while it was saved")
            await KeymasterSession.shared.clear()
            return
        }

        isSignedIn = true
        // Connected through the player's lifecycle, as every other connect is, while the
        // app shows: its profile and start page need no session, and the window's own
        // `initializeIfNeeded` waits for this one. A connect that fails is said in the
        // now-playing bar, as any other is, and Speakers offers it again.
        await PlaybackViewModel.shared.initializeIfNeeded()
    }

    /// Starts the grant and keeps hold of it, so it can be abandoned.
    ///
    /// The task lives here rather than in the view because the view that started it can be
    /// torn down — switching away from Speakers, or the login step giving way to the app —
    /// while the browser round-trip is still outstanding.
    func startStreamingAuthorization() {
        guard streamingAuthorization == nil else { return }

        authorizationRun &+= 1
        let run = authorizationRun
        streamingAuthorization = Task { [weak self] in
            await self?.authorizeStreaming()
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
    /// `isInitialized` true,
    /// since the connection subscription deliberately does not clear it on a disconnect, so
    /// the app would hide the re-authorization affordance and keep aiming plays at a player
    /// that no longer exists.
    ///
    /// Only then are the credentials removed — the keymaster tokens in the keychain and
    /// librespot's AP credentials, which are a file and would otherwise let the next launch
    /// connect the account that just logged out. After the teardown, so no live session can
    /// write them back.
    func logout() async {
        // Invalidates any streaming grant still deciding, so it cannot resume into the
        // session this is tearing down.
        authLifecycle &+= 1
        // A grant's refusal belongs to the session it was refused in, not to the login screen.
        errorMessage = nil

        await PlaybackViewModel.shared.shutdownForLogout()
        await SpotifyPlayer.clearStreamingCredentials()
        isSignedIn = false
    }
}
