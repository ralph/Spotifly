//
//  QueueTests.swift
//  SpotiflyTests
//
//  The player's queue as the app's rows, the metadata asked for them, which row is drawn as
//  playing, and which refused commands are declines.
//

import Foundation
@testable import Spotifly
import Testing

/// The queue's rows, worked out from what the player last published.
@MainActor
struct QueueEntriesTests {
    private func item(_ id: String, provider: String = "context") -> QueueItem {
        QueueItem(uri: "spotify:track:\(id)", provider: provider)
    }

    /// Before the first snapshot, and after a logout clears it.
    @Test func `no snapshot is an empty queue`() {
        let queue = Queue(nil)

        #expect(queue.currentTrack == nil)
        #expect(queue.length == 0)
        #expect(queue.trackIds.isEmpty)
    }

    @Test func `history comes with the rest, in play order`() {
        let queue = Queue(QueueState(
            contextUri: "",
            currentTrack: item("playing"),
            nextTracks: [item("pending"), item("later")],
            previousTracks: [item("earlier"), item("played")],
        ))

        #expect(queue.previousTracks.map(\.trackId) == ["earlier", "played"])
        #expect(queue.currentTrack?.trackId == "playing")
        #expect(queue.nextTracks.map(\.trackId) == ["pending", "later"])
        #expect(queue.currentIndex == 2)
        #expect(queue.length == 5)
        #expect(queue.trackIds == ["earlier", "played", "playing", "pending", "later"])
    }

    /// Nothing is playing but the cluster still knows what is queued.
    @Test func `pending tracks alone are a queue`() {
        let queue = Queue(QueueState(contextUri: "", currentTrack: nil, nextTracks: [item("pending")], previousTracks: []))

        #expect(queue.currentTrack == nil)
        #expect(queue.nextTracks.map(\.trackId) == ["pending"])
        #expect(queue.length == 1)
    }

    /// Another device's rows keep the cluster's uid, which a skip to one of them names.
    @Test func `a row keeps its uid`() {
        var next = item("next")
        next.uid = "c3e1a9d6"
        let queue = Queue(QueueState(contextUri: "", currentTrack: item("playing"), nextTracks: [next], previousTracks: []))

        #expect(queue.nextTracks.map(\.uid) == ["c3e1a9d6"])
        #expect(queue.currentTrack?.uid == nil)
    }

    /// The cluster can name things this app has no row for, and a queue is not a reason to
    /// invent one.
    @Test func `items that are not tracks are dropped`() {
        let episode = QueueItem(uri: "spotify:episode:e1", provider: "context")
        let queue = Queue(QueueState(
            contextUri: "",
            currentTrack: item("playing"),
            nextTracks: [episode, item("pending")],
            previousTracks: [],
        ))

        #expect(queue.nextTracks.map(\.trackId) == ["pending"])
    }

    /// The queue view tells a track queued by hand from one the context supplied.
    @Test func `the provider survives the conversion`() {
        let queue = Queue(QueueState(contextUri: "", currentTrack: nil, nextTracks: [item("queued", provider: "queue")], previousTracks: []))

        #expect(queue.nextTracks.first?.provider == .queue)
    }

    /// A bare list of tracks has an empty context uri, and names no context.
    @Test func `a queue names its context, and a bare list none`() {
        let album = QueueState(contextUri: "spotify:album:alive", currentTrack: item("a1"), nextTracks: [], previousTracks: [])
        let bareList = QueueState(contextUri: "", currentTrack: item("t1"), nextTracks: [], previousTracks: [])

        #expect(album.context == "spotify:album:alive")
        #expect(bareList.context == nil)
    }

    /// The rows are read from the snapshot the model holds, so they change with it, and a logout,
    /// which clears the snapshot's queue, leaves none.
    @Test func `the model's rows follow its snapshots`() {
        let model = PlayerModel()
        var snapshot = PlayerSnapshot()
        snapshot.queue = QueueState(contextUri: "", currentTrack: item("playing"), nextTracks: [], previousTracks: [])
        model.apply(snapshot)

        #expect(model.queueEntries.currentTrack?.trackId == "playing")

        snapshot.queue = nil
        model.apply(snapshot)

        #expect(model.queueEntries.length == 0)
    }
}

/// The metadata the queue's rows need, which the store is asked to hold.
@MainActor
struct QueueHydrationTests {
    /// A fetch that failed is not retried by the queue's observation when the queue comes back
    /// unchanged, as after a reconnect; `hydrate()` is what asks again.
    @Test func `hydrate asks again for what a failed fetch left missing`() async throws {
        let store = AppStore()
        let player = PlayerModel()
        var snapshot = PlayerSnapshot()
        snapshot.queue = QueueState(
            contextUri: "",
            currentTrack: QueueItem(uri: "spotify:track:playing", provider: "context"),
            nextTracks: [],
            previousTracks: [],
        )
        player.apply(snapshot)
        let attempts = Attempts()
        let trackService = TrackService(
            store: store,
            metadataFetcher: { trackIds in
                attempts.count += 1
                if attempts.count == 1 {
                    throw URLError(.notConnectedToInternet)
                }
                return Dictionary(uniqueKeysWithValues: trackIds.map { ($0, track(id: $0)) })
            },
        )
        let queueService = QueueService(store: store, trackService: trackService, player: player)

        queueService.activate()
        try await waitForDebounce { attempts.count == 1 }
        #expect(store.tracks["playing"] == nil)

        queueService.hydrate()
        try await waitForDebounce { store.tracks["playing"] != nil }
        #expect(attempts.count == 2)
    }

    /// Waits out the queue service's 100 ms debounce, which `waitUntil`'s yields do not.
    private func waitForDebounce(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition never became true")
    }
}

@MainActor
private final class Attempts {
    var count = 0
}

/// Which row of a list is drawn as playing.
///
/// A list can legitimately hold the same recording twice — an album with a reprise, a playlist
/// a track was added to twice, or two catalogue entries that relink to one market id. Deciding
/// by uri lights up all of them, which is what drew two rows of an 11-track queue green while
/// only one of them advanced.
@MainActor
struct CurrentRowIdentityTests {
    /// The queue knows a current *position*, so position is what it uses.
    @Test func `only the row at the current index is current`() {
        let currentIndex = 0
        let uris = [
            "spotify:track:street",
            "spotify:track:away",
            "spotify:track:street",
        ]

        let flags = uris.indices.map { index in
            TrackRow.isCurrent(index: index, currentIndex: currentIndex, uri: uris[index], playingUri: uris[0])
        }

        #expect(flags == [true, false, false])
    }

    @Test func `a later position is current when playback has advanced`() {
        let uris = ["spotify:track:street", "spotify:track:away", "spotify:track:street"]

        let flags = uris.indices.map { index in
            TrackRow.isCurrent(index: index, currentIndex: 2, uri: uris[index], playingUri: uris[2])
        }

        #expect(flags == [false, false, true])
    }

    /// Lists with no current position — an album page, a playlist, search results — have
    /// nothing better than the uri to go on, and keep the old behaviour.
    @Test func `without a current index the uri decides`() {
        #expect(TrackRow.isCurrent(index: 3, currentIndex: nil, uri: "spotify:track:a", playingUri: "spotify:track:a"))
        #expect(!TrackRow.isCurrent(index: 3, currentIndex: nil, uri: "spotify:track:a", playingUri: "spotify:track:b"))
    }

    @Test func `a row with no index at all falls back to the uri`() {
        #expect(TrackRow.isCurrent(index: nil, currentIndex: 0, uri: "spotify:track:a", playingUri: "spotify:track:a"))
    }
}

/// Telling Spotify declining from something being wrong.
///
/// Thirteen of twenty-eight commands in one measured session failed, and every one was a
/// control the user had pressed deliberately against a device or a state that would not take
/// it. Reporting those as errors makes a working app look broken.
struct DeclinedCommandTests {
    @Test func `a restricted skip is a decline, not a failure`() {
        let error = SpclientError.requestFailed(
            403,
            #"{"error_code":"9","error_description":"skip_to_prev_restricted","reasons":["no_prev_track"]}"#,
        )

        #expect(error.isDeclined)
        #expect(error.isNoPreviousTrack)
    }

    /// An iPhone will not take a remote volume change — iOS policy, not a Spotify one.
    @Test func `an unsupported command is a decline, not a failure`() {
        let error = SpclientError.requestFailed(400, #"{"error_type":"DEVICE_DOES_NOT_SUPPORT_COMMAND"}"#)

        #expect(error.isDeclined)
        #expect(!error.isNoPreviousTrack)
    }

    @Test func `a genuine failure is still a failure`() {
        let missing = SpclientError.requestFailed(404, #"{"error_type":"DEVICE_NOT_FOUND"}"#)
        let broken = SpclientError.requestFailed(500, "")

        #expect(!missing.isDeclined)
        #expect(!broken.isDeclined)
    }

    @Test func `the body is carried into the message so a log says why`() {
        let error = SpclientError.requestFailed(400, #"{"error_type":"DEVICE_DOES_NOT_SUPPORT_COMMAND"}"#)

        #expect(error.localizedDescription.contains("400"))
        #expect(error.localizedDescription.contains("DEVICE_DOES_NOT_SUPPORT_COMMAND"))
    }
}
