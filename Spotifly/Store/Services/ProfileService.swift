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

    /// Whether a profile request has answered this session, even with a profile that has no name,
    /// which asking again would not change.
    private var answered = false
    /// The asking again after a failed launch request; see `loadForSession()`.
    private var sessionLoad: Task<Void, Never>?
    /// The pauses before each time it asks again, the last one repeating. Injected, with the
    /// wait itself, so tests do not wait.
    private let retryPauses: [Duration]
    private let pause: @Sendable (Duration) async throws -> Void

    init(
        store: AppStore,
        partnerAPI: PartnerAPI = PartnerAPI(),
        retryPauses: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(300)],
        pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    ) {
        self.store = store
        self.partnerAPI = partnerAPI
        self.retryPauses = retryPauses
        self.pause = pause
    }

    isolated deinit {
        sessionLoad?.cancel()
    }

    /// Loads the profile for the session: once now, then, after a failure, again after growing
    /// pauses until a request answers.
    ///
    /// The owner-only actions decide by `store.userId`, read synchronously: Remove from this
    /// playlist, Edit Details, the cover and Delete, and the playlists Add to playlist offers. A
    /// launch request that failed while the network stayed up was asked again only when the
    /// network returned, so until a relaunch they were missing. A failure that may pass soon is
    /// already asked again inside the request (`SpotifyCredentials.retryingPassingFailures`);
    /// this is for the rest, and for one that did not pass in those seconds.
    ///
    /// Returns when the first attempt has ended, so the launch waits for it as long as it did.
    /// The asking again goes on in the background, and ends with the service, which is the
    /// session's. The network's return still asks at once (`LoggedInLifecycleModifier`).
    func loadForSession() async {
        guard sessionLoad == nil, !answered else { return }
        do {
            try await reload()
            return
        } catch {
            debugLog("ProfileService", "Profile unavailable: \(error.localizedDescription); asking again in \(retryPauses.first?.components.seconds ?? 0) s")
        }

        sessionLoad = Task { [weak self, retryPauses, pause] in
            var pauses = retryPauses.makeIterator()
            var delay = Duration.seconds(300)
            while true {
                delay = pauses.next() ?? delay
                do {
                    try await pause(delay)
                } catch {
                    return
                }
                guard let self, !answered else { return }
                do {
                    try await reload()
                    debugLog("ProfileService", "Profile loaded on asking again")
                    return
                } catch {
                    debugLog("ProfileService", "Profile still unavailable: \(error.localizedDescription)")
                }
            }
        }
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
        answered = true
    }
}
