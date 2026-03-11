import Testing

@testable import Spotifly

@MainActor
struct QueueServiceReconnectTests {
    @Test func emptyReconnectSnapshotDoesNotClearExistingQueue() async throws {
        let store = AppStore()
        store.setQueue(
            previous: [],
            current: QueueEntry(trackId: "current", provider: .context),
            next: [QueueEntry(trackId: "next", provider: .context)]
        )

        let service = QueueService(
            store: store,
            tokenProvider: { "token" },
            api: QueueServiceAPI(
                fetchPlaybackState: { _ in nil },
                fetchQueue: { _ in
                    SpotifyAPI.QueueResponse(currentlyPlaying: nil, queue: [])
                }
            )
        )

        await service.fetchInitialPlaybackState(accessToken: "token", recoveryMode: .reconnecting)

        #expect(store.queue.currentTrack?.trackId == "current")
        #expect(store.queue.nextTracks.map(\.trackId) == ["next"])
    }

    @Test func emptyStartupSnapshotStillClearsQueue() async throws {
        let store = AppStore()
        store.setQueue(
            previous: [],
            current: QueueEntry(trackId: "current", provider: .context),
            next: [QueueEntry(trackId: "next", provider: .context)]
        )

        let service = QueueService(
            store: store,
            tokenProvider: { "token" },
            api: QueueServiceAPI(
                fetchPlaybackState: { _ in nil },
                fetchQueue: { _ in
                    SpotifyAPI.QueueResponse(currentlyPlaying: nil, queue: [])
                }
            )
        )

        await service.fetchInitialPlaybackState(accessToken: "token")

        #expect(store.queue.currentTrack == nil)
        #expect(store.queue.nextTracks.isEmpty)
    }
}
