//
//  KeymasterSession.swift
//  Spotifly
//
//  Holds the keymaster tokens, and keeps them fresh.
//

import Combine
import Foundation

/// The live keymaster grant: one access token, kept valid, shared by everything that needs it.
///
/// An actor because the token is read from several places at once — the accesspoint session,
/// pathfinder and spclient — and a refresh must happen once rather than once per caller.
/// Concurrent callers arriving during a refresh await the same one.
actor KeymasterSession {
    /// The app's grant. One instance, because one grant is what the app has: the accesspoint
    /// session and both API clients read the same token, and a second instance would refresh
    /// against a rotating token the first has already spent.
    static let shared = KeymasterSession()

    /// Announces that the grant is gone and cannot come back.
    ///
    /// A signal rather than a thrown error because the response is not the caller's: every
    /// request in the app reads this token, and each of them failing separately is what the
    /// retry loop looked like. One announcement, one place that acts on it.
    ///
    /// Per instance, deliberately, not a file-scope subject like the ones in `SpotifyPlayer`.
    /// Tests build their own `KeymasterSession` precisely so they cannot touch the real grant —
    /// and a shared subject hands that back, because a test session's revocation would reach
    /// the app's live `AuthViewModel` and log the developer out of their own keychain.
    ///
    /// `nonisolated(unsafe)` because Combine subjects are thread-safe and subscribing must not
    /// require awaiting the actor.
    private nonisolated(unsafe) let revokedSubject = PassthroughSubject<Void, Never>()

    /// Fires once when a refresh comes back `invalid_grant`. The tokens are already forgotten
    /// by then; what remains is the rest of logging out, which the view model owns.
    nonisolated var grantRevoked: AnyPublisher<Void, Never> {
        revokedSubject.eraseToAnyPublisher()
    }

    /// Injected so the rotation policy can be tested without a network. The real one is
    /// `KeymasterAuth.refresh`.
    typealias Refresher = @Sendable (String) async throws -> KeymasterTokens

    private let store: KeymasterTokenStoring
    private let refresher: Refresher
    private var tokens: KeymasterTokens?
    private var refreshInFlight: Task<KeymasterTokens, Error>?
    /// Advanced by `supersedeRefresh()`. A refresh that was in flight when the grant was
    /// cleared or replaced must not write what it eventually returns — that would put the
    /// signed-out account's refresh token straight back into the keychain.
    private var generation = 0

    init(
        store: KeymasterTokenStoring = KeymasterKeychainStore(),
        refresher: @escaping Refresher = { try await KeymasterAuth.refresh(refreshToken: $0) },
    ) {
        self.store = store
        self.refresher = refresher
        tokens = store.load()
    }

    /// Whether a grant has been completed on this machine.
    var hasGrant: Bool {
        tokens != nil
    }

    /// The account the grant authenticated as, if there is one.
    var username: String? {
        tokens?.username
    }

    /// Records the outcome of a fresh grant.
    func adopt(_ newTokens: KeymasterTokens) throws {
        supersedeRefresh()
        tokens = newTokens
        try store.save(newTokens)
    }

    /// Forgets the grant — on logout, or when the refresh token is dead.
    func clear() {
        supersedeRefresh()
        tokens = nil
        store.clear()
    }

    /// Abandons any refresh in flight and disowns whatever it eventually returns.
    ///
    /// A refresh spends the *previous* refresh token, and Spotify keeps one live token per
    /// client id and account — so a refresh that started before a new grant either returns
    /// tokens that grant has already replaced, and overwrites it, or is refused as
    /// `invalid_grant` for the token it retired, and discards it. The second is the likelier of
    /// the two and logs the user out moments after they authorized. Re-authorizing while signed
    /// in is a real path here: Speakers and the play alert both offer it.
    ///
    /// Cancellation is cooperative, so the network call can still succeed afterwards; the
    /// generation is what stops its result from being written.
    private func supersedeRefresh() {
        generation &+= 1
        refreshInFlight?.cancel()
        refreshInFlight = nil
    }

    /// A token that is valid now, refreshing first if it is close enough to expiry.
    ///
    /// Throws rather than returning nil when there is no grant: every caller needs a token to
    /// do anything at all, and "not authorized yet" is a state the UI already handles.
    func accessToken(now: Date = Date()) async throws -> String {
        guard let current = tokens else {
            throw KeymasterSessionError.noGrant
        }

        guard current.needsRefresh(now: now) else {
            return current.accessToken
        }

        return try await refreshed(from: current).accessToken
    }

    private func refreshed(from current: KeymasterTokens) async throws -> KeymasterTokens {
        // A second caller during a refresh joins the one already running. Two concurrent
        // refreshes would each spend the same rotating token, and the loser's replacement
        // would be the one Spotify has already invalidated.
        if let refreshInFlight {
            return try await refreshInFlight.value
        }

        let startedAt = generation
        let task = Task { [refresher] () throws -> KeymasterTokens in
            try await refresher(current.refreshToken)
        }

        refreshInFlight = task
        // Only if the slot still holds *this* run. `adopt` and `clear` both empty it, and a
        // later refresh can have filled it again by the time this one unwinds — clearing that
        // one would let a second refresh start against the same rotating token, which is the
        // race the single-flight exists to prevent.
        defer {
            if refreshInFlight == task {
                refreshInFlight = nil
            }
        }

        let renewed: KeymasterTokens
        do {
            renewed = try await task.value
        } catch KeymasterAuthError.grantRevoked {
            // Nothing to retry: this refresh token is dead and every later attempt spends the
            // same one. Left in place it fails forever and survives relaunch, because the
            // keychain item outlives the process — so forgetting it here is the whole fix for
            // the loop, and the announcement is what gets the user back to a sign-in.
            //
            // Guarded like the success path below: a logout during the network call already
            // cleared this grant, and a sign-in behind it may have adopted a *good* one. The
            // revocation belongs to the token this run spent, not to whatever holds the slot
            // now.
            guard startedAt == generation else {
                throw KeymasterSessionError.noGrant
            }

            clear()
            revokedSubject.send()
            throw KeymasterSessionError.grantRevoked
        }

        // Back on the actor. A logout that landed during the network call already cleared the
        // grant, so this result belongs to an account that is gone — persisting it would
        // recreate the keychain item behind logout's back.
        guard startedAt == generation else {
            throw KeymasterSessionError.noGrant
        }

        // Only the initial exchange carries the username, so a refresh that omits it must not
        // blank the stored one.
        var merged = renewed
        if merged.username.isEmpty {
            merged.username = current.username
        }

        try store.save(merged)
        tokens = merged
        return merged
    }
}

nonisolated enum KeymasterSessionError: Error, LocalizedError, Equatable {
    case noGrant
    /// The grant was refused as dead and has been discarded. Separate from `noGrant` so a log
    /// says which of the two happened — a grant that never existed, or one that stopped being
    /// accepted mid-session.
    case grantRevoked

    var errorDescription: String? {
        switch self {
        case .noGrant:
            "This Mac has not been authorized for playback yet"
        case .grantRevoked:
            "Session expired, please sign in again"
        }
    }
}
