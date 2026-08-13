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

/// Adding tracks, which writes optimistically and then has to reconcile.
@MainActor
struct PlaylistAddReconciliationTests {
    /// A one-item playlist carrying a real uid, as a load would have left it.
    private func seededStore() -> AppStore {
        let store = AppStore()
        store.upsertPlaylist(
            Playlist(
                id: "p1",
                name: "Mix",
                description: nil,
                images: ImageSet(variants: []),
                uri: "spotify:playlist:p1",
                isPublic: true,
                ownerId: "ralph",
                ownerName: "Ralph",
                externalUrl: nil,
                items: [PlaylistItem(uid: "aaaa1111", trackId: "t1")],
                totalDurationMs: 0,
                knownTrackCount: 1,
                tracksLoaded: true,
            ),
        )
        return store
    }

    /// Routes by operation name: the mutation succeeds, the reload behind it does not.
    private func api(reloadStatus: Int) -> PartnerAPI {
        PartnerAPI(
            accessToken: { "at" },
            clientToken: { "ct" },
            transport: { request in
                let body = try #require(request.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let isMutation = json["operationName"] as? String == "addToPlaylist"

                let payload = isMutation
                    ? Data(#"{"data":{"addItemsToPlaylist":{"__typename":"AddItemsToPlaylistPayload"}}}"#.utf8)
                    : Data()
                let response = HTTPURLResponse(
                    url: PartnerAPI.endpoint,
                    statusCode: isMutation ? 200 : reloadStatus,
                    httpVersion: nil,
                    headerFields: nil,
                )!
                return (payload, response)
            },
        )
    }

    /// The add succeeded, so the row belongs there — but it carries a locally generated uid,
    /// and only the reload replaces it with Spotify's. Leaving the playlist marked loaded meant
    /// nothing ever fetched it again, and a removal or a drag would send a `local:` uid the
    /// service has never heard of.
    @Test func `an add whose refresh fails leaves the contents reloadable`() async throws {
        let store = seededStore()
        let service = PlaylistService(store: store, partnerAPI: api(reloadStatus: 500))

        await #expect(throws: (any Error).self) {
            try await service.addTracksToPlaylist(playlistId: "p1", trackIds: ["t2"])
        }

        let playlist = try #require(store.playlists["p1"])
        // The optimistic row stays on screen; only the "these are Spotify's uids" claim goes.
        #expect(playlist.items.count == 2)
        #expect(playlist.tracksLoaded == false)
        #expect(playlist.items.contains { $0.uid.hasPrefix("local:") })
    }

    @Test func `an add is not marked stale when nothing failed`() async throws {
        let store = seededStore()
        let reload = Data("""
        {"data":{"playlistV2":{"__typename":"Playlist","uri":"spotify:playlist:p1","name":"Mix",
          "ownerV2":{"data":{"__typename":"User","username":"ralph","name":"Ralph",
                             "uri":"spotify:user:ralph"}},
          "content":{"totalCount":2,"items":[
            {"uid":"aaaa1111","itemV2":{"data":{"uri":"spotify:track:t1","name":"One",
              "trackDuration":{"totalMilliseconds":1000}}}},
            {"uid":"bbbb2222","itemV2":{"data":{"uri":"spotify:track:t2","name":"Two",
              "trackDuration":{"totalMilliseconds":1000}}}}]}}}}
        """.utf8)

        let service = PlaylistService(
            store: store,
            partnerAPI: PartnerAPI(
                accessToken: { "at" },
                clientToken: { "ct" },
                transport: { request in
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let isMutation = json["operationName"] as? String == "addToPlaylist"
                    let payload = isMutation
                        ? Data(#"{"data":{"addItemsToPlaylist":{"__typename":"AddItemsToPlaylistPayload"}}}"#.utf8)
                        : reload
                    let response = HTTPURLResponse(
                        url: PartnerAPI.endpoint,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil,
                    )!
                    return (payload, response)
                },
            ),
        )

        try await service.addTracksToPlaylist(playlistId: "p1", trackIds: ["t2"])

        let playlist = try #require(store.playlists["p1"])
        #expect(playlist.tracksLoaded)
        #expect(playlist.items.map(\.uid) == ["aaaa1111", "bbbb2222"])
    }
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
