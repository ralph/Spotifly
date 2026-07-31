//
//  TrackServiceTests.swift
//  SpotiflyTests
//
//  Cancellation and deduplication behavior for favorite-status checks.
//

@testable import Spotifly
import Testing

@MainActor
struct TrackServiceTests {
    @Test func `cached metadata returns without fetching a token`() async throws {
        let store = AppStore()
        store.upsertTrack(Track(from: apiTrack(id: "cached")))
        let tokens = TrackMetadataCounter()
        let requests = TrackMetadataRecorder()
        let service = TrackService(
            store: store,
            tokenProvider: { tokens.count += 1; return "token" },
            metadataFetcher: { _, trackIds in
                requests.trackIdBatches.append(trackIds)
                return metadata(for: trackIds)
            },
        )

        try await service.ensureTracksLoaded(trackIds: ["cached", "cached"])

        #expect(tokens.count == 0)
        #expect(requests.trackIdBatches.isEmpty)
    }

    @Test func `overlapping metadata batches fetch each track once`() async throws {
        let store = AppStore()
        let gate = TrackMetadataGate()
        let requests = TrackMetadataRecorder()
        let service = TrackService(
            store: store,
            tokenProvider: { "token" },
            metadataFetcher: { _, trackIds in
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
        try await waitForTrackMetadataCondition { requests.trackIdBatches.count == 1 }

        let second = Task {
            try await service.ensureTracksLoaded(trackIds: ["b", "c"])
        }
        try await waitForTrackMetadataCondition { requests.trackIdBatches.count == 2 }

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
        let requests = TrackMetadataCounter()
        let service = TrackService(
            store: store,
            tokenProvider: { "token" },
            metadataFetcher: { _, trackIds in
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

    @Test func `metadata load survives caller cancellation and remains shared`() async throws {
        let store = AppStore()
        let gate = TrackMetadataGate()
        let requests = TrackMetadataCounter()
        let replacementFinished = TrackMetadataCounter()
        let service = TrackService(
            store: store,
            tokenProvider: { "token" },
            metadataFetcher: { _, trackIds in
                requests.count += 1
                await gate.wait()
                return metadata(for: trackIds)
            },
        )

        let original = Task {
            try await service.ensureTracksLoaded(trackIds: ["shared"])
        }
        try await waitForTrackMetadataCondition { requests.count == 1 }

        let replacement = Task {
            try await service.ensureTracksLoaded(trackIds: ["shared"])
            replacementFinished.count += 1
        }
        await settleTrackMetadataTasks()

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
        let requestGate = FavoriteStatusGate()
        let requests = FavoriteStatusCounter()
        let replacementFinished = FavoriteStatusCounter()
        let service = TrackService(
            store: store,
            tokenProvider: { "token" },
            favoriteStatusFetcher: { _, trackIds in
                requests.count += 1
                await requestGate.wait()
                try Task.checkCancellation()
                return Dictionary(uniqueKeysWithValues: trackIds.map { ($0, true) })
            },
        )

        let original = Task {
            await service.ensureFavoriteStatuses(trackIds: ["track"])
        }
        try await waitForFavoriteStatusCondition { requests.count == 1 }

        let replacement = Task {
            await service.ensureFavoriteStatuses(trackIds: ["track"])
            replacementFinished.count += 1
        }
        await settleFavoriteStatusTasks()

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
private final class TrackMetadataCounter {
    var count = 0
}

@MainActor
private final class TrackMetadataRecorder {
    var trackIdBatches: [[String]] = []
}

@MainActor
private final class TrackMetadataGate {
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
private func metadata(for trackIds: [String]) -> [String: APITrack] {
    Dictionary(uniqueKeysWithValues: trackIds.map { ($0, apiTrack(id: $0)) })
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

@MainActor
private func waitForTrackMetadataCondition(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition never became true")
}

@MainActor
private func settleTrackMetadataTasks() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}

@MainActor
private final class FavoriteStatusCounter {
    var count = 0
}

@MainActor
private final class FavoriteStatusGate {
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
private func waitForFavoriteStatusCondition(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition never became true")
}

@MainActor
private func settleFavoriteStatusTasks() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}
