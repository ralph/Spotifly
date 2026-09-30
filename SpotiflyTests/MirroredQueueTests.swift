//
//  MirroredQueueTests.swift
//  SpotiflyTests
//
//  The queue another device reports, as the Queue section shows it.
//

import Foundation
@testable import Spotifly
import Testing

struct MirroredQueueTests {
    private func row(_ id: String, hidden: Bool = false, iteration: Int = 0) -> ProvidedTrack {
        var track = ProvidedTrack(uri: "spotify:track:\(id)", uid: "uid-\(id)-\(iteration)")
        track.metadata = ["iteration": "\(iteration)"]
        if hidden {
            track.metadata["hidden"] = "true"
        }
        return track
    }

    private func delimiter(iteration: Int) -> ProvidedTrack {
        var track = ProvidedTrack(uri: "spotify:delimiter", uid: "delimiter\(iteration)")
        track.metadata = ["hidden": "true", "iteration": "\(iteration)"]
        return track
    }

    /// The shape the web player sent on 2026-09-30 for an album: its rows, a delimiter, then
    /// the album again as the next iteration.
    private func album(nextIterationHidden: Bool) -> PlayerState {
        var state = PlayerState()
        state.contextUri = "spotify:album:a"
        state.nextTracks = [row("t2"), row("t3"), delimiter(iteration: 0)]
            + ["t1", "t2", "t3"].map { row($0, hidden: nextIterationHidden, iteration: 1) }
            + [delimiter(iteration: 1)]
        return state
    }

    @Test func `with repeat off, the queue ends with the context's last track`() {
        let state = album(nextIterationHidden: true)

        let queue = LibrespotClient.mirroredQueue(of: state, current: row("t1"))

        #expect(queue.nextTracks.map(\.uri) == ["spotify:track:t2", "spotify:track:t3"])
        #expect(queue.context == "spotify:album:a")
    }

    @Test func `with repeat on, the next iteration shows, without its delimiters`() {
        let state = album(nextIterationHidden: false)

        let queue = LibrespotClient.mirroredQueue(of: state, current: row("t1"))

        #expect(queue.nextTracks.map(\.uri) == ["t2", "t3", "t1", "t2", "t3"].map { "spotify:track:\($0)" })
    }

    @Test func `a hidden row before the current track is left out too`() {
        var state = PlayerState()
        state.prevTracks = [row("t1"), delimiter(iteration: 0)]

        let queue = LibrespotClient.mirroredQueue(of: state, current: row("t2"))

        #expect(queue.previousTracks.map(\.uri) == ["spotify:track:t1"])
    }
}
