//
//  ProfileService.swift
//  Spotifly
//
//  Who is logged in: one request for it, however many callers ask at once.
//

import Foundation

@MainActor
@Observable
final class ProfileService {
    private let store: AppStore
    private let partnerAPI: PartnerAPI

    /// The profile request, one run at a time under one key.
    private let requests = InFlightRequests<Void>()
    private static let key = "user-profile"

    init(store: AppStore, partnerAPI: PartnerAPI = PartnerAPI()) {
        self.store = store
        self.partnerAPI = partnerAPI
    }

    /// The logged-in user's profile, fetched when the store does not hold it yet.
    ///
    /// The launch asks for it and swallows a failure, since an app that cannot say who you are
    /// is still an app that plays music. The playlist library's writes ask too, and need it:
    /// they address the rootlist by username. So a write fetches it rather than refusing, which
    /// is what kept one transient failure at launch from leaving create, delete, follow and
    /// unfollow throwing `accountUnknown` until a relaunch. Through the registry, so the launch
    /// and several writes arriving at once ask for it once.
    func require() async throws -> UserProfile {
        if let profile = store.userProfile {
            return profile
        }

        try await requests.run(Self.key) {
            let profile = try await self.partnerAPI.profile()
            self.store.setUserProfile(UserProfile(pathfinder: profile))
        }

        // A profile can arrive without the one field that matters — `UserProfile(pathfinder:)`
        // is failable precisely because a nameless account cannot address a rootlist.
        guard let profile = store.userProfile else {
            throw SpclientError.accountUnknown
        }
        return profile
    }
}
