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

    /// `plans/done/queue-rows-have-no-identity.md`: `backward()` went back to the first copy
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

    /// Measured with the web player: Liked Songs playing its second row, a track queued and
    /// skipped into, then handed over. The session's uid named the third row, where the context
    /// goes on after the queued track.
    @Test func `a queued track handed over plays as queued, and the context goes on at the row named`() throws {
        let tracks = ["t0", "t1", "t2", "t3"]
        let start = try #require(PlaybackQueue.start(in: tracks, queued: "q1", resumingAt: "u2", uids: ["u0", "u1", "u2", "u3"]))
        #expect(start.tracks == tracks)
        #expect(start.index == 1)
        #expect(start.queued == "q1")

        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: start.tracks, startIndex: start.index)
        queue.replaceUserQueue(with: ["q2"])
        queue.playQueued("q1")

        #expect(queue.currentUri == "q1")
        #expect(queue.currentProvider == "queue")
        #expect(queue.upcoming().map(\.uri) == ["q2", "t2", "t3"])
        #expect(queue.history == ["t1"])
        #expect(queue.advance() == "q2")
        #expect(queue.advance() == "t2")
    }

    /// Found by its uri instead, a queued track the context also lists moved the context to
    /// that row, passing over the rows before it.
    @Test func `before the first row, the queued track goes in front, not where the context lists it`() throws {
        let start = try #require(PlaybackQueue.start(in: ["t0", "q1", "t2"], queued: "q1", resumingAt: "u0", uids: ["u0", "u1", "u2"]))

        #expect(start.tracks == ["q1", "t0", "q1", "t2"])
        #expect(start.index == 0)
        #expect(start.queued == nil)
    }

    @Test func `a uid the context does not list leaves the queued track to start`() {
        #expect(PlaybackQueue.start(in: ["t0", "t1"], queued: "q1", resumingAt: "other", uids: ["u0", "u1"]) == nil)
        // An album's resolve answer carries no uids.
        #expect(PlaybackQueue.start(in: ["t0", "t1"], queued: "q1", resumingAt: "u1", uids: [nil, nil]) == nil)
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

    /// The handover of 2026-09-30: "Today Is a Gift" handed over as the relinked
    /// `7dF8hsVoSdDWT6GlJZpBPm`, which Liked Songs lists as `0sMImBteCIVUKNhcyx3Cyx`.
    @Test func `a uid names the row a relinked track plays from`() {
        let uids: [String?] = ["u-a", "u-b", "u-c", "u-b2", "u-d"]

        let start = PlaybackQueue.start(in: tracks, index: nil, uri: "relinked", uid: "u-c", uids: uids)

        #expect(start.index == 2)
        #expect(start.tracks == tracks)
    }

    /// Without an index, the uri alone took the first copy of a track the context holds twice.
    @Test func `a uid names which copy of a repeated track was handed over`() {
        let uids: [String?] = ["u-a", "u-b", "u-c", "u-b2", "u-d"]

        #expect(PlaybackQueue.start(in: tracks, index: nil, uri: "b", uid: "u-b2", uids: uids).index == 3)
    }

    @Test func `a uid the context does not list leaves the uri to decide`() {
        let uids: [String?] = [nil, nil, nil, nil, nil]

        #expect(PlaybackQueue.start(in: tracks, index: nil, uri: "c", uid: "u-c", uids: uids).index == 2)
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

/// Rows named by uid, as Connect names them: a queued track's own, and a context row's from
/// the resolver, so another device can name one copy of a track apart from another.
struct QueueRowUidTests {
    private func uids(_ rows: [QueueItem]) -> [String?] {
        rows.map(\.uid)
    }

    @Test func `queued tracks are named q0, q1 and on, and keep the name while they play`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["t0", "t1"], startIndex: 0)
        queue.enqueue("x")
        queue.enqueue("y")

        #expect(uids(queue.upcoming()) == ["q0", "q1", nil])

        _ = queue.advance()
        #expect(queue.currentUri == "x")
        #expect(queue.current?.uid == "q0")
        #expect(uids(queue.upcoming()) == ["q1", nil])

        // Queued later, a new name: the count goes on.
        queue.enqueue("z")
        #expect(uids(queue.upcoming()) == ["q1", "q2", nil])
    }

    @Test func `context rows carry the resolver's uids, ahead, current and behind`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: ["a", "b", "c"], uids: ["u0", "u1", "u2"], startIndex: 1)

        #expect(queue.current?.uid == "u1")
        #expect(uids(queue.upcoming()) == ["u2"])

        _ = queue.advance()
        #expect(uids(queue.recent()) == ["u1"])
    }

    @Test func `a context without uids has none, and short uids are padded`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a", "b", "c"], uids: ["u0"], startIndex: 0)

        #expect(queue.current?.uid == "u0")
        #expect(uids(queue.upcoming()) == [nil, nil])
    }

    /// The case the web player's provider could not tell apart, measured 2026-10-01: a track
    /// queued, and the same track further on in the context.
    @Test func `a uid names the context's copy of a track that is also queued`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: ["a", "b", "x", "c"], uids: ["u0", "u1", "u2", "u3"], startIndex: 0)
        queue.enqueue("x")

        #expect(queue.skip(toUpcoming: nil, uri: "x", uid: "u2") == "x")
        #expect(queue.contextPosition == 2)
        #expect(queue.current?.uid == "u2")
        // The queued copy stays queued, as a context target leaves it.
        #expect(queue.upcoming().map(\.uri) == ["x", "c"])
    }

    @Test func `a uid names the queued copy too`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: ["a", "x"], uids: ["u0", "u1"], startIndex: 0)
        queue.enqueue("x")

        #expect(queue.skip(toUpcoming: nil, uri: "x", uid: "q0") == "x")
        #expect(queue.currentProvider == "queue")
    }

    /// A uid that names nothing ahead, or names another track, falls back to the uri.
    @Test func `a uid that names no row ahead leaves the uri to decide`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: ["a", "b", "c"], uids: ["u0", "u1", "u2"], startIndex: 0)

        #expect(queue.skip(toUpcoming: nil, uri: "c", uid: "u1") == "c")
        #expect(queue.current?.uid == "u2")
    }

    @Test func `a track put in where the context lacks it has no uid, and the rest keep theirs`() {
        let start = PlaybackQueue.start(in: ["a", "b"], index: 1, uri: "x", uids: ["u0", "u1"])

        #expect(start.tracks == ["a", "x", "b"])
        #expect(start.uids == ["u0", nil, "u1"])
        #expect(start.index == 1)
    }

    @Test func `a queued track put in front of the context leaves the context's uids in place`() throws {
        let start = try #require(PlaybackQueue.start(in: ["a", "b"], queued: "x", resumingAt: "u0", uids: ["u0", "u1"]))

        #expect(start.tracks == ["x", "a", "b"])
        #expect(start.uids == [nil, "u0", "u1"])
    }

    /// The album's rows from pathfinder, after the resolver gave none: the case of
    /// `plans/done/queued-copy-of-an-album-track.md`, the queued copy of a track further on.
    @Test func `an album's rows take the uids listed for them, and a jump names its copy`() {
        let album = PlaybackQueue()
        album.setContext(uri: "spotify:album:a", tracks: ["a", "b", "x", "c"], startIndex: 0)
        album.enqueue("x")

        #expect(album.adoptRowUids([("a", "u0"), ("b", "u1"), ("x", "u2"), ("c", "u3")], ofContext: "spotify:album:a"))
        #expect(album.current?.uid == "u0")
        #expect(uids(album.upcoming()) == ["q0", "u1", "u2", "u3"])
        #expect(album.skip(toUpcoming: nil, uri: "x", uid: "u2") == "x")
        #expect(album.contextPosition == 2)
    }

    @Test func `a track the album lists twice gets each copy's uid`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a", "b", "a"], startIndex: 0)

        #expect(queue.adoptRowUids([("a", "u0"), ("b", "u1"), ("a", "u2")], ofContext: "spotify:album:a"))
        #expect(queue.current?.uid == "u0")
        #expect(uids(queue.upcoming()) == ["u1", "u2"])
    }

    /// A row put in at the start, as a queued track a handover names goes in front: matched by
    /// place, every uid after it would move a row on.
    @Test func `uids follow their tracks, not their places`() {
        #expect(PlaybackQueue.rowUids([("a", "u0"), ("b", "u1")], of: ["x", "a", "b", "c"]) == [nil, "u0", "u1", nil])
    }

    /// Asked for after the track started: by then another context may play, or the rows have
    /// uids of their own.
    @Test func `uids are not taken for another context, nor over the rows' own`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:b", tracks: ["a", "b"], startIndex: 0)
        #expect(!queue.adoptRowUids([("a", "u0")], ofContext: "spotify:album:a"))
        #expect(queue.current?.uid == nil)

        queue.setContext(uri: "spotify:playlist:p", tracks: ["a", "b"], uids: ["p0", "p1"], startIndex: 0)
        #expect(!queue.adoptRowUids([("a", "u0")], ofContext: "spotify:playlist:p"))
        #expect(queue.current?.uid == "p0")
    }
}

/// The next round of a context under repeat, which other devices are shown and a jump can reach,
/// as librespot's `fill_up_next_tracks` lists it.
struct RepeatRoundTests {
    private func album(at index: Int, repeat mode: PlaybackQueue.RepeatMode = .context) -> PlaybackQueue {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a", "b", "c"], uids: ["u0", "u1", "u2"], startIndex: index)
        queue.setRepeat(mode)
        return queue
    }

    @Test func `under repeat, the context starts again after its end, as often as there is room`() {
        let queue = album(at: 1)

        #expect(queue.upcoming(limit: 6, rounds: .asPlayed).map(\.uri) == ["c", "a", "b", "c", "a", "b"])
        // The queue view lists one round, and its count says how long the album is.
        #expect(queue.upcoming().map(\.uri) == ["c"])
    }

    @Test func `other devices are told where it starts over, as librespot tells them`() {
        let queue = album(at: 2)
        queue.enqueue("q")

        let rows = queue.upcoming(limit: 6, rounds: .asReported)

        #expect(rows.map(\.uri) == ["q", PlaybackQueue.delimiterUri, "a", "b", "c", PlaybackQueue.delimiterUri])
        #expect(rows.map(\.uid) == ["q0", "delimiter0", "u0", "u1", "u2", "delimiter1"])
        #expect(rows.map(\.hidden) == [false, true, false, false, false, true])
    }

    @Test func `without repeat, or shuffled, there is no next round`() {
        #expect(album(at: 2, repeat: .off).upcoming(rounds: .asPlayed).isEmpty)
        #expect(album(at: 2, repeat: .track).upcoming(rounds: .asPlayed).isEmpty)

        let shuffled = album(at: 0)
        shuffled.setShuffle(true)
        #expect(shuffled.upcoming(rounds: .asPlayed).count == 2)
    }

    /// Before, a track behind the current one was listed nowhere ahead, and the jump failed.
    @Test func `a jump reaches a track in the next round`() {
        let queue = album(at: 2)

        #expect(queue.skip(toUpcoming: nil, uri: "a", uid: "u0") == "a")
        #expect(queue.contextPosition == 0)
        #expect(queue.history == ["c"])
    }

    /// So the fetch-ahead has the first track ready when the last one ends.
    @Test func `on the last track, the next one is the first`() {
        #expect(album(at: 2).upcomingPlayable(skipping: { _ in false }) == "a")
        #expect(album(at: 2, repeat: .off).upcomingPlayable(skipping: { _ in false }) == nil)
    }
}

/// A station's rows a page at a time: the next page's url waits in the queue, and its rows join the
/// context's own when they come.
struct StationPageQueueTests {
    @Test func `a page's rows join the context's own, and name the page after them`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:station:track:x", tracks: ["a", "b"], startIndex: 1, nextPage: "page2")

        #expect(queue.upcoming().isEmpty)
        #expect(queue.nextPageUrl == "page2")

        queue.appendPage(["c", "d"], uids: ["u3", "u4"], next: "page3")
        #expect(queue.upcoming().map(\.uri) == ["c", "d"])
        #expect(queue.upcoming().map(\.provider) == ["context", "context"])
        #expect(queue.nextPageUrl == "page3")
        #expect(queue.advance() == "c")
    }

    @Test func `another context drops the page, a rewind keeps it`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:station:track:x", tracks: ["a", "b"], startIndex: 1, nextPage: "page2")
        queue.rewind(to: 0)
        #expect(queue.nextPageUrl == "page2")

        queue.setContext(uri: "spotify:album:y", tracks: ["c"], startIndex: 0)
        #expect(queue.nextPageUrl == nil)
    }

    /// A playlist longer than the pages fetched up front comes a page at a time too.
    @Test func `shuffled, a page's rows come after the rows not yet played`() {
        let queue = PlaybackQueue()
        queue.setShuffle(true)
        queue.setContext(uri: "spotify:playlist:long", tracks: ["a", "b", "c"], startIndex: 0, nextPage: "page2")
        let before = Set(queue.upcoming().map(\.uri))

        queue.appendPage(["d", "e"], uids: [nil, nil], next: nil)
        let upcoming = queue.upcoming().map(\.uri)
        #expect(Set(upcoming.prefix(before.count)) == before)
        #expect(Set(upcoming.dropFirst(before.count)) == ["d", "e"])
    }
}

/// A context's restrictions, as the resolver names them for a station (2026-10-02).
struct ContextRestrictionQueueTests {
    @Test func `a station starts unshuffled and without repeat, in its own order`() {
        let queue = PlaybackQueue()
        queue.setShuffle(true)
        queue.setRepeat(.context)
        queue.setContext(uri: "spotify:station:track:x", tracks: ["a", "b", "c"], startIndex: 0, nextPage: "page2", restrictions: .radio)

        #expect(!queue.shuffleEnabled)
        #expect(queue.repeatMode == .off)
        #expect(queue.upcoming().map(\.uri) == ["b", "c"])
    }

    @Test func `repeat-one, which a station allows, stays on`() {
        let queue = PlaybackQueue()
        queue.setRepeat(.track)
        queue.setContext(uri: "spotify:station:track:x", tracks: ["a", "b"], startIndex: 0, restrictions: .radio)

        #expect(queue.repeatMode == .track)
    }

    @Test func `a context without restrictions keeps the options`() {
        let queue = PlaybackQueue()
        queue.setShuffle(true)
        queue.setRepeat(.context)
        queue.setContext(uri: "spotify:album:y", tracks: ["a", "b", "c"], startIndex: 0)

        #expect(queue.shuffleEnabled)
        #expect(queue.repeatMode == .context)
    }

    @Test func `a rewind keeps the restrictions, and the next context has its own`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:station:track:x", tracks: ["a", "b"], startIndex: 1, restrictions: .radio)
        queue.rewind(to: 0)
        #expect(queue.restrictions == .radio)

        queue.setContext(uri: "spotify:album:y", tracks: ["c"], startIndex: 0)
        #expect(queue.restrictions.isEmpty)
    }
}
