//
//  ProfileService.swift
//  Spotifly
//
//  Who is logged in: the one place that asks Spotify for it.
//

import Foundation

@MainActor
@Observable
final class ProfileService {
    private let store: AppStore
    private let partnerAPI: PartnerAPI

    /// The writes' profile request, one run at a time under one key.
    private let requests = InFlightRequests<Void>()
    private static let key = "user-profile"

    init(store: AppStore, partnerAPI: PartnerAPI = PartnerAPI()) {
        self.store = store
        self.partnerAPI = partnerAPI
    }

    /// The logged-in user's profile, fetched when the store does not hold it yet.
    ///
    /// For the playlist library's writes, which address the rootlist by username. Fetching it
    /// rather than refusing is what keeps one transient failure at launch from leaving create,
    /// delete, follow and unfollow throwing `accountUnknown` until a relaunch. Through the
    /// registry, so several writes arriving at once ask for it once.
    func require() async throws -> UserProfile {
        if let profile = store.userProfile {
            return profile
        }

        try await requests.run(Self.key) {
            try await self.reload()
        }

        // A profile can arrive without the one field that matters — `UserProfile(pathfinder:)`
        // is failable precisely because a nameless account cannot address a rootlist.
        guard let profile = store.userProfile else {
            throw SpclientError.accountUnknown
        }
        return profile
    }

    /// Asks for the profile, whatever the store holds, and never joins a request in flight.
    ///
    /// For the launch and the network's return. Joining would let the retry join a request the
    /// launch started offline, and fail with it; see
    /// `plans/done/list-failures-the-retry-cannot-see.md`.
    func reload() async throws {
        let profile = try await partnerAPI.profile()
        store.setUserProfile(UserProfile(pathfinder: profile))
    }
}
