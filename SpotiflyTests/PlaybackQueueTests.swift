//
//  PlaybackQueueTests.swift
//  SpotiflyTests
//

@testable import Spotifly
import Testing

/// The ordering the Swift playback stack runs on. Pure logic, no network —
/// and the first thing under `SwiftLibrespot` with any coverage at all.
struct PlaybackQueueTests {
    private func album(_ count: Int) -> [String] {
        (0 ..< count).map { "spotify:track:t\($0)" }
    }

    // MARK: - Plain traversal

    @Test func `advance walks the context and stops at the end`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)

        #expect(queue.currentUri == "spotify:track:t0")
        #expect(queue.advance() == "spotify:track:t1")
        #expect(queue.advance() == "spotify:track:t2")
        #expect(queue.advance() == nil)
    }

    @Test func `history is in play order, the most recent last`() {
        let tracks = album(14)
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: tracks, startIndex: 0)

        for _ in 0 ..< 3 {
            _ = queue.advance()
        }
        #expect(queue.recent().map(\.uri) == Array(tracks[..<3]))

        for _ in 0 ..< 10 {
            _ = queue.advance()
        }
        #expect(queue.currentUri == tracks[13])
        #expect(queue.recent().map(\.uri) == Array(tracks[3 ..< 13]))
    }

    @Test func `repeat context wraps back to the first track`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(2), startIndex: 0)
        queue.setRepeat(.context)

        #expect(queue.advance() == "spotify:track:t1")
        #expect(queue.advance() == "spotify:track:t0")
    }

    @Test func `repeat track replays only for auto advance`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)
        queue.setRepeat(.track)

        #expect(queue.advance() == "spotify:track:t0")
        // A manual skip moves regardless of repeat-one.
        #expect(queue.advance(respectingRepeat: false) == "spotify:track:t1")
    }

    @Test func `queued tracks play before the context resumes`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)
        queue.enqueue("spotify:track:q0")

        #expect(queue.advance() == "spotify:track:q0")
        #expect(queue.currentUri == "spotify:track:q0")
        // The context carries on from where it was, not from the queued track.
        #expect(queue.advance() == "spotify:track:t1")
    }

    /// `plans/done/history-repeats-the-track-before-a-queued-one.md`: the context track before
    /// a queued one went into the history twice.
    @Test func `a queued track leaves the context track before it in the history once`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1", "t2"], startIndex: 0)
        queue.enqueue("q0")

        #expect(queue.advance() == "q0")
        #expect(queue.advance() == "t1")
        #expect(queue.history == ["t0"])
        #expect(queue.recent().map(\.uri) == ["t0"])

        #expect(queue.backward() == "t0")
        #expect(queue.currentUri == "t0")
        #expect(queue.backward() == nil)
    }

    /// The history held `[t0, q1, t0]`: a queued track followed by another was kept, the last
    /// of a run was not, and t0 went in twice.
    @Test func `a run of queued tracks keeps none of them in the history`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1", "t2"], startIndex: 0)
        queue.enqueue("q1")
        queue.enqueue("q2")

        #expect(queue.advance() == "q1")
        #expect(queue.advance() == "q2")
        #expect(queue.history == ["t0"])
        #expect(queue.backward() == "t0")
        #expect(queue.currentUri == "t0")

        _ = queue.advance()
        #expect(queue.currentUri == "t1")
        #expect(queue.history == ["t0"])
    }

    /// `plans/open/queue-rows-have-no-identity.md`: `backward()` went back to the first copy
    /// of a track the context holds twice, whichever copy had played.
    @Test func `Previous returns to the copy of a repeated track that played`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a", "b", "a", "c"], startIndex: 2)
        _ = queue.advance()

        #expect(queue.backward() == "a")
        #expect(queue.contextPosition == 2)
        // And the context carries on from there, not from the first copy.
        #expect(queue.advance() == "c")
    }

    @Test func `backward returns along history`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)

        _ = queue.advance()
        _ = queue.advance()
        #expect(queue.canGoBackward)
        #expect(queue.backward() == "spotify:track:t1")
        #expect(queue.backward() == "spotify:track:t0")
        #expect(queue.backward() == nil)
    }

    // MARK: - Shuffle

    @Test func `shuffle visits every track exactly once`() throws {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(8), startIndex: 0)
        queue.setShuffle(true)

        var visited = try [#require(queue.currentUri)]
        while let next = queue.advance() {
            visited.append(next)
        }

        #expect(visited.count == 8)
        #expect(Set(visited).count == 8)
    }

    /// Running off the end of a shuffled context used to walk `shufflePosition`
    /// past `shuffleOrder.count`, and the very next `upcoming()` — which every
    /// caller of `advance` reaches through `publishQueueNotifications` — sliced
    /// from there and trapped with "Range requires lowerBound <= upperBound".
    /// Shuffle on, repeat off, skip past the last track: the app died.
    @Test func `exhausting a shuffled context leaves the queue readable`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)
        queue.setShuffle(true)

        while queue.advance() != nil {}

        #expect(queue.advance() == nil)
        #expect(queue.upcoming().isEmpty)

        // And it stays survivable however often the end is hit.
        _ = queue.advance()
        _ = queue.advance()
        #expect(queue.upcoming().isEmpty)
    }

    /// Shuffle is random, so this asserts the one ordering that is excluded
    /// rather than any particular result — and repeats, because a permutation
    /// that happens to avoid it once proves nothing.
    @Test func `a shuffled context that repeats never opens on the track it just finished`() throws {
        for _ in 0 ..< 50 {
            let queue = PlaybackQueue()
            queue.setContext(uri: "spotify:album:a", tracks: album(3), startIndex: 0)
            queue.setShuffle(true)
            queue.setRepeat(.context)

            var lastOfCycle = try #require(queue.currentUri)
            for _ in 1 ..< 3 {
                lastOfCycle = try #require(queue.advance())
            }

            #expect(queue.advance() != lastOfCycle)
        }
    }

    @Test func `upcoming lists the queue first, then what is left of the context`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: album(4), startIndex: 1)
        queue.enqueue("spotify:track:q0")

        let upcoming = queue.upcoming()
        #expect(upcoming.map(\.uri) == ["spotify:track:q0", "spotify:track:t2", "spotify:track:t3"])
        #expect(upcoming.map(\.provider) == ["queue", "context", "context"])
    }
}

/// Where the current track sits, which a transfer away hands to the next device.
struct PlaybackQueuePositionTests {
    @Test func `the context position follows the current track`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1", "t2"], startIndex: 1)

        #expect(queue.contextPosition == 1)
        #expect(queue.currentProvider == "context")

        _ = queue.advance()
        #expect(queue.contextPosition == 2)
    }

    @Test func `a queued track has no context position`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1"], startIndex: 0)
        queue.enqueue("q")

        _ = queue.advance()

        #expect(queue.currentUri == "q")
        #expect(queue.contextPosition == nil)
        #expect(queue.currentProvider == "queue")
    }
}

/// A handover brings the sender's queue, which replaces whatever was left here.
struct PlaybackQueueHandoverTests {
    @Test func `replacing the user queue drops what was queued before`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1"], startIndex: 0)
        queue.enqueue("stale")

        queue.replaceUserQueue(with: ["q1", "q2"])

        #expect(queue.upcoming().map(\.uri) == ["q1", "q2", "t1"])
    }
}

/// Where a context starts when a row names its index and its track. The index counts rows in
/// the view's list, which is not the resolved context, so the track decides and the index only
/// says which copy. See `plans/done/clicked-row-plays-another-track.md`.
struct ContextStartTests {
    /// `b` twice, at 1 and 3.
    private let tracks = ["a", "b", "c", "b", "d"]

    @Test func `the index wins when it names the track`() {
        let start = PlaybackQueue.start(in: tracks, index: 3, uri: "b")

        #expect(start.index == 3)
        #expect(start.tracks == tracks)
    }

    /// The Liked Songs case before #77: the list and the context in another order.
    @Test func `a stale index finds the track wherever it is`() {
        #expect(PlaybackQueue.start(in: tracks, index: 0, uri: "c").index == 2)
        #expect(PlaybackQueue.start(in: tracks, index: 4, uri: "a").index == 0)
    }

    @Test func `of two copies, the one nearer the index wins`() {
        #expect(PlaybackQueue.start(in: tracks, index: 0, uri: "b").index == 1)
        #expect(PlaybackQueue.start(in: tracks, index: 4, uri: "b").index == 3)
    }

    @Test func `a tie goes to the earlier copy`() {
        #expect(PlaybackQueue.start(in: tracks, index: 2, uri: "b").index == 1)
    }

    /// A list older than the context: the clicked track still plays, and what follows it is
    /// what followed its row.
    @Test func `a track the context does not name goes in at the index`() {
        let start = PlaybackQueue.start(in: tracks, index: 2, uri: "x")

        #expect(start.index == 2)
        #expect(start.tracks == ["a", "b", "x", "c", "b", "d"])
    }

    /// A resume or a handover names a track without an index, as it always did.
    @Test func `without an index, a track the context does not name goes in front`() {
        let start = PlaybackQueue.start(in: tracks, index: nil, uri: "x")

        #expect(start.index == 0)
        #expect(start.tracks == ["x"] + tracks)
    }

    @Test func `an index past the end is clamped, then checked against the track`() {
        #expect(PlaybackQueue.start(in: tracks, index: 99, uri: nil).index == 4)
        #expect(PlaybackQueue.start(in: tracks, index: 99, uri: "d").index == 4)
        #expect(PlaybackQueue.start(in: tracks, index: 99, uri: "a").index == 0)
    }

    @Test func `an index alone is taken as it is`() {
        #expect(PlaybackQueue.start(in: tracks, index: 2, uri: nil).index == 2)
    }

    @Test func `a track alone starts at its first copy`() {
        #expect(PlaybackQueue.start(in: tracks, index: nil, uri: "b").index == 1)
    }

    @Test func `neither starts at the top`() {
        let start = PlaybackQueue.start(in: tracks, index: nil, uri: nil)

        #expect(start.index == 0)
        #expect(start.tracks == tracks)
    }
}

/// A double-click on a queue row: the queue moves to that row and keeps what it had.
struct QueueJumpTests {
    private func queue(_ tracks: [String]) -> PlaybackQueue {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: tracks, startIndex: 0)
        return queue
    }

    private func album(_ count: Int) -> [String] {
        (0 ..< count).map { "t\($0)" }
    }

    private func upcoming(_ queue: PlaybackQueue) -> [String] {
        queue.upcoming().map(\.uri)
    }

    @Test func `a context row ahead plays, and the tracks passed over go into the history`() {
        let queue = queue(album(6))

        #expect(queue.skip(toUpcoming: 2, uri: "t3") == "t3")
        #expect(queue.currentUri == "t3")
        #expect(queue.history == ["t0", "t1", "t2"])
        #expect(upcoming(queue) == ["t4", "t5"])
    }

    /// The plan's case: they were dropped, because the context was resolved again.
    @Test func `queued tracks stay queued when a context row is chosen`() {
        let queue = queue(album(5))
        queue.enqueue("q0")
        queue.enqueue("q1")

        #expect(queue.skip(toUpcoming: 3, uri: "t2") == "t2")
        #expect(upcoming(queue) == ["q0", "q1", "t3", "t4"])
    }

    @Test func `a queued row plays, and the queued tracks before it are skipped`() {
        let queue = queue(album(3))
        queue.enqueue("q0")
        queue.enqueue("q1")
        queue.enqueue("q2")

        #expect(queue.skip(toUpcoming: 1, uri: "q1") == "q1")
        #expect(queue.currentUri == "q1")
        #expect(upcoming(queue) == ["q2", "t1", "t2"])
    }

    @Test func `under shuffle, the shuffle order is kept`() {
        let queue = queue(album(8))
        queue.setShuffle(true)
        let before = upcoming(queue)

        #expect(queue.skip(toUpcoming: 3, uri: before[3]) == before[3])
        #expect(upcoming(queue) == Array(before.dropFirst(4)))
    }

    /// A list can hold the same track more than once, so the row's track decides and its
    /// index says which copy.
    @Test func `the track decides, and the index picks the copy nearest it`() {
        let queue = queue(["a", "b", "a", "c", "a"])

        #expect(queue.skip(toUpcoming: 2, uri: "b") == "b")
        #expect(queue.contextPosition == 1)

        #expect(queue.skip(toUpcoming: 2, uri: "a") == "a")
        #expect(queue.contextPosition == 4)
    }

    /// A `skip_next` from another device names a track and no index: librespot steps to the
    /// first copy ahead.
    @Test func `without an index, the first copy ahead plays`() {
        let queue = queue(["a", "b", "a", "c", "a"])

        #expect(queue.skip(toUpcoming: nil, uri: "a") == "a")
        #expect(queue.contextPosition == 2)
    }

    @Test func `a row no longer listed plays nothing and moves nothing`() {
        let queue = queue(album(3))

        #expect(queue.skip(toUpcoming: 0, uri: "gone") == nil)
        #expect(queue.stepBack(toRecent: 0, uri: "gone") == nil)
        #expect(queue.currentUri == "t0")
        #expect(upcoming(queue) == ["t1", "t2"])
    }

    /// Looked up through `recent()`, the list the view shows, whichever order it has.
    @Test func `a history row steps back to it, as Previous would`() throws {
        let queue = queue(album(5))
        _ = queue.skip(toUpcoming: 2, uri: "t3")
        let row = try #require(queue.recent().firstIndex { $0.uri == "t1" })

        #expect(queue.stepBack(toRecent: row, uri: "t1") == "t1")
        #expect(queue.currentUri == "t1")
        #expect(queue.history == ["t0"])
        #expect(upcoming(queue) == ["t2", "t3", "t4"])
    }
}
