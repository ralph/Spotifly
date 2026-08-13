//
//  KeymasterSession.swift
//  Spotifly
//
//  Holds the keymaster tokens, and keeps them fresh.
//

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

    /// Injected so the rotation policy can be tested without a network. The real one is
    /// `KeymasterAuth.refresh`.
    typealias Refresher = @Sendable (String) async throws -> KeymasterTokens

    private let store: KeymasterTokenStoring
    private let refresher: Refresher
    private var tokens: KeymasterTokens?
    private var refreshInFlight: Task<KeymasterTokens, Error>?
    /// Advanced by `clear()`. A refresh that was in flight when the grant was cleared must not
    /// write what it eventually returns: cancellation is cooperative, so the network call can
    /// still succeed after a logout and would otherwise put the signed-out account's refresh
    /// token straight back into the keychain.
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
        tokens = newTokens
        try store.save(newTokens)
    }

    /// Forgets the grant — on logout, or when the refresh token is dead.
    func clear() {
        generation &+= 1
        tokens = nil
        refreshInFlight?.cancel()
        refreshInFlight = nil
        store.clear()
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
        defer { refreshInFlight = nil }

        let renewed = try await task.value

        // Back on the actor. A logout that landed during the network call already cleared the
        // grant, so this result belongs to an account that is gone — persisting it would
        // recreate the keychain item behind logout's back.
        guard startedAt == generation else {
            throw KeymasterSessionError.noGrant
        }

        let merged = merge(renewed, keeping: current)
        try store.save(merged)
        tokens = merged
        return merged
    }

    /// Carries forward what a refresh response does not repeat.
    private func merge(_ renewed: KeymasterTokens, keeping current: KeymasterTokens) -> KeymasterTokens {
        renewed.username.isEmpty
            ? KeymasterTokens(
                accessToken: renewed.accessToken,
                refreshToken: renewed.refreshToken,
                expiresAt: renewed.expiresAt,
                username: current.username,
            )
            : renewed
    }
}

nonisolated enum KeymasterSessionError: Error, LocalizedError {
    case noGrant

    var errorDescription: String? {
        switch self {
        case .noGrant:
            "This Mac has not been authorized for playback yet"
        }
    }
}
