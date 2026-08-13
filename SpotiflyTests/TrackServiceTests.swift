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
        store.upsertTrack(Track(from: apiTrack(id: "cached")))
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
        let gate = RequestGate()
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
        try await waitForCondition { requests.trackIdBatches.count == 1 }

        let second = Task {
            try await service.ensureTracksLoaded(trackIds: ["b", "c"])
        }
        try await waitForCondition { requests.trackIdBatches.count == 2 }

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
        let requests = RequestCounter()
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
        let requests = RequestCounter()
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
        let requests = RequestCounter()
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
        let gate = RequestGate()
        let requests = RequestCounter()
        let replacementFinished = RequestCounter()
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
        try await waitForCondition { requests.count == 1 }

        let replacement = Task {
            try await service.ensureTracksLoaded(trackIds: ["shared"])
            replacementFinished.count += 1
        }
        await settleTasks()

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
        let requestGate = RequestGate()
        let requests = RequestCounter()
        let replacementFinished = RequestCounter()
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
        try await waitForCondition { requests.count == 1 }

        let replacement = Task {
            await service.ensureFavoriteStatuses(trackIds: ["track"])
            replacementFinished.count += 1
        }
        await settleTasks()

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
private final class RequestCounter {
    var count = 0
}

@MainActor
private final class RequestRecorder {
    var trackIdBatches: [[String]] = []
}

/// Holds a fake request open until the test decides it may finish.
@MainActor
private final class RequestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming {
            waiter.resume()
        }
    }
}

@MainActor
private func metadata(for trackIds: [String]) -> [String: Track] {
    Dictionary(uniqueKeysWithValues: trackIds.map { ($0, Track(from: apiTrack(id: $0))) })
}

@MainActor
private func apiTrack(id: String) -> APITrack {
    APITrack(
        id: id,
        addedAt: nil,
        albumId: "album",
        albumName: "Album",
        artistId: "artist",
        artistName: "Artist",
        durationMs: 180_000,
        externalUrl: nil,
        images: .empty,
        name: "Track \(id)",
        trackNumber: 1,
        uri: "spotify:track:\(id)",
    )
}

/// Yields until `condition` holds, so a test can wait for an unstructured task to
/// reach a point without sleeping for a fixed duration.
@MainActor
private func waitForCondition(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition never became true")
}

/// Gives every already-started task a chance to run, so a following assertion about
/// what did *not* happen is meaningful.
@MainActor
private func settleTasks() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}
