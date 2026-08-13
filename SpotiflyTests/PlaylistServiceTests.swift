//
//  PlaylistServiceTests.swift
//  SpotiflyTests
//
//  The library writes, which cannot address a rootlist without knowing whose it is.
//

import Foundation
@testable import Spotifly
import Testing

/// Trimmed from a real `profileAttributes` response, 2026-08-13 — the same one
/// `PathfinderProfileTests` decodes.
private let profileJSON = Data("""
{"data":{"me":{"profile":{
  "accountId":"pOTWfwsjEH",
  "avatar":{"sources":[{"height":300,"url":"https://i.scdn.co/image/ab6775700000ee8502b7","width":300}]},
  "name":"llralphj","socialHandle":null,
  "uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y","username":"qixixbr0ox6sik6jc6bkv6y6y"}}}}
""".utf8)

/// Counts what each client was asked for, and answers.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var profileRequests = 0
    private(set) var rootlistWrites = 0
    /// How many profile requests fail before one succeeds.
    private let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func profile() throws -> (Data, URLResponse) {
        try lock.withLock {
            profileRequests += 1
            let response = HTTPURLResponse(
                url: PartnerAPI.endpoint,
                statusCode: profileRequests <= failuresBeforeSuccess ? 500 : 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (profileJSON, response)
        }
    }

    func rootlist(_ request: URLRequest) -> (Data, URLResponse) {
        lock.withLock {
            rootlistWrites += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (Data("{}".utf8), response)
        }
    }
}

@MainActor
private func makeService(_ calls: Calls) -> (PlaylistService, AppStore) {
    let store = AppStore()
    let service = PlaylistService(
        store: store,
        partnerAPI: PartnerAPI(
            accessToken: { "at" },
            clientToken: { "ct" },
            transport: { _ in try calls.profile() },
        ),
        spclientAPI: SpclientAPI(
            accessToken: { "at" },
            clientToken: { "ct" },
            transport: { calls.rootlist($0) },
        ),
    )
    return (service, store)
}

@MainActor
struct PlaylistLibraryWriteTests {
    /// The startup profile request swallows its own failure — nothing on that path should block
    /// on it — and nothing retried it, so one transient failure used to leave create, delete,
    /// follow and unfollow throwing `accountUnknown` until the app was relaunched.
    @Test func `a write fetches the profile when the startup request did not land it`() async throws {
        let calls = Calls()
        let (service, store) = makeService(calls)
        #expect(store.userProfile == nil)

        try await service.followPlaylist(playlistId: "p1")

        #expect(calls.profileRequests == 1)
        #expect(calls.rootlistWrites == 1)
        #expect(store.userProfile?.id == "qixixbr0ox6sik6jc6bkv6y6y")
    }

    @Test func `a profile already in the store costs no request`() async throws {
        let calls = Calls()
        let (service, store) = makeService(calls)

        let decoded = try JSONDecoder().decode(PathfinderProfileResponse.self, from: profileJSON)
        try store.setUserProfile(UserProfile(pathfinder: #require(decoded.profile)))

        try await service.followPlaylist(playlistId: "p1")

        #expect(calls.profileRequests == 0)
        #expect(calls.rootlistWrites == 1)
    }

    /// The failure is still a failure — this is a retry on the next attempt, not a retry loop.
    @Test func `a write whose profile request fails throws, and the next one tries again`() async throws {
        let calls = Calls(failuresBeforeSuccess: 1)
        let (service, store) = makeService(calls)

        await #expect(throws: (any Error).self) {
            try await service.followPlaylist(playlistId: "p1")
        }
        #expect(store.userProfile == nil)
        #expect(calls.rootlistWrites == 0)

        try await service.followPlaylist(playlistId: "p1")

        #expect(calls.profileRequests == 2)
        #expect(calls.rootlistWrites == 1)
    }

    /// Four writes can be in flight at once; the profile is one fact and should cost one
    /// request, which is what the registry is for.
    @Test func `concurrent writes share one profile request`() async throws {
        let calls = Calls()
        let (service, _) = makeService(calls)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 4 {
                group.addTask { @MainActor in
                    try await service.followPlaylist(playlistId: "p\(index)")
                }
            }
            try await group.waitForAll()
        }

        #expect(calls.profileRequests == 1)
        #expect(calls.rootlistWrites == 4)
    }
}
