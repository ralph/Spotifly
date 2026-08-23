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
