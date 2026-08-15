//
//  TrackServiceTests.swift
//  SpotiflyTests
//
//  Cancellation and deduplication behavior for track metadata loads and
//  favorite-status checks.
//

@testable import Spotifly
import Testing

@MainActor
struct TrackServiceTests {
    /// The token half of this test is gone with the Web API: `TrackService` runs entirely on
    /// the keymaster grant now, which `PartnerAPI` holds, so there is no token for a cache hit
    /// to avoid taking. What it still guards is the part that matters — a track already in the
    /// store costs no request.
    @Test func `cached metadata returns without a request`() async throws {
        let store = AppStore()
        store.upsertTracks([track(id: "cached")])
        let requests = RequestRecorder()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.trackIdBatches.append(trackIds)
                return metadata(for: trackIds)
            },
        )

        try await service.ensureTracksLoaded(trackIds: ["cached", "cached"])

        #expect(requests.trackIdBatches.isEmpty)
    }

    @Test func `overlapping metadata batches fetch each track once`() async throws {
        let store = AppStore()
        let gate = MainActorGate()
        let requests = RequestRecorder()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.trackIdBatches.append(trackIds)
                if trackIds.contains("a") {
                    await gate.wait()
                }
                return metadata(for: trackIds)
            },
        )

        let first = Task {
            try await service.ensureTracksLoaded(trackIds: ["a", "b"])
        }
        try await waitUntil { requests.trackIdBatches.count == 1 }

        let second = Task {
            try await service.ensureTracksLoaded(trackIds: ["b", "c"])
        }
        try await waitUntil { requests.trackIdBatches.count == 2 }

        let requestedIds = requests.trackIdBatches.flatMap(\.self)
        #expect(requestedIds.filter { $0 == "a" }.count == 1)
        #expect(requestedIds.filter { $0 == "b" }.count == 1)
        #expect(requestedIds.filter { $0 == "c" }.count == 1)

        gate.open()
        try await first.value
        try await second.value

        #expect(Set(store.tracks.keys).isSuperset(of: ["a", "b", "c"]))
    }

    @Test func `failed metadata can be retried`() async throws {
        let store = AppStore()
        let requests = MainActorCounter()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.count += 1
                if requests.count == 1 {
                    throw TrackMetadataFailure()
                }
                return metadata(for: trackIds)
            },
        )

        await #expect(throws: TrackMetadataFailure.self) {
            try await service.ensureTracksLoaded(trackIds: ["retry"])
        }
        try await service.ensureTracksLoaded(trackIds: ["retry"])

        #expect(requests.count == 2)
        #expect(store.tracks["retry"]?.name == "Track retry")
    }

    @Test func `a track the api answers without is not requested again`() async throws {
        let store = AppStore()
        let requests = MainActorCounter()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.count += 1
                // Spotify omits IDs that do not resolve for this market.
                return metadata(for: trackIds.filter { $0 != "unavailable" })
            },
        )

        try await service.ensureTracksLoaded(trackIds: ["unavailable", "present"])
        try await service.ensureTracksLoaded(trackIds: ["unavailable", "present"])

        #expect(requests.count == 1)
        #expect(store.tracks["present"] != nil)
        #expect(store.tracks["unavailable"] == nil)
    }

    @Test func `a failed request does not mark its tracks unavailable`() async throws {
        let store = AppStore()
        let requests = MainActorCounter()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.count += 1
                if requests.count == 1 {
                    throw TrackMetadataFailure()
                }
                return metadata(for: trackIds)
            },
        )

        await #expect(throws: TrackMetadataFailure.self) {
            try await service.ensureTracksLoaded(trackIds: ["transient"])
        }
        try await service.ensureTracksLoaded(trackIds: ["transient"])

        #expect(requests.count == 2)
        #expect(store.tracks["transient"] != nil)
    }

    @Test func `metadata load survives caller cancellation and remains shared`() async throws {
        let store = AppStore()
        let gate = MainActorGate()
        let requests = MainActorCounter()
        let replacementFinished = MainActorCounter()
        let service = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                requests.count += 1
                await gate.wait()
                return metadata(for: trackIds)
            },
        )

        let original = Task {
            try await service.ensureTracksLoaded(trackIds: ["shared"])
        }
        try await waitUntil { requests.count == 1 }

        let replacement = Task {
            try await service.ensureTracksLoaded(trackIds: ["shared"])
            replacementFinished.count += 1
        }
        await settle()

        original.cancel()
        gate.open()
        try await original.value
        try await replacement.value

        #expect(requests.count == 1)
        #expect(replacementFinished.count == 1)
        #expect(store.tracks["shared"] != nil)
    }

    @Test func `a replacement caller awaits a favorite check after the original caller is cancelled`() async throws {
        let store = AppStore()
        let requestGate = MainActorGate()
        let requests = MainActorCounter()
        let replacementFinished = MainActorCounter()
        let service = TrackService(
            store: store,
            favoriteStatusFetcher: { trackIds in
                requests.count += 1
                await requestGate.wait()
                try Task.checkCancellation()
                return Dictionary(uniqueKeysWithValues: trackIds.map { ($0, true) })
            },
        )

        let original = Task {
            await service.ensureFavoriteStatuses(trackIds: ["track"])
        }
        try await waitUntil { requests.count == 1 }

        let replacement = Task {
            await service.ensureFavoriteStatuses(trackIds: ["track"])
            replacementFinished.count += 1
        }
        await settle()

        #expect(requests.count == 1)
        #expect(replacementFinished.count == 0)

        original.cancel()
        requestGate.open()
        await original.value
        await replacement.value

        #expect(requests.count == 1)
        #expect(replacementFinished.count == 1)
        #expect(store.hasResolvedFavoriteStatus(for: "track"))
        #expect(store.isFavorite("track"))
    }
}

private struct TrackMetadataFailure: Error {}

@MainActor
private final class RequestRecorder {
    var trackIdBatches: [[String]] = []
}

@MainActor
private func metadata(for trackIds: [String]) -> [String: Track] {
    Dictionary(uniqueKeysWithValues: trackIds.map { ($0, track(id: $0)) })
}
