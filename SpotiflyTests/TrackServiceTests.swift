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
