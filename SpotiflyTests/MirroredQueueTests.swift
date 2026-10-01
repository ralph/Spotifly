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
    private func row(_ id: String, hidden: Bool = false) -> ProvidedTrack {
        var track = ProvidedTrack(uri: "spotify:track:\(id)", uid: "uid-\(id)")
        track.metadata = hidden ? ["hidden": "true"] : [:]
        return track
    }

    private let delimiter: ProvidedTrack = {
        var track = ProvidedTrack(uri: "spotify:delimiter")
        track.metadata = ["hidden": "true"]
        return track
    }()

    /// The shape the web player sent on 2026-09-30 for an album: its rows, a delimiter, then
    /// the album again as the next iteration.
    private func album(nextIterationHidden: Bool) -> PlayerState {
        var state = PlayerState()
        state.contextUri = "spotify:album:a"
        state.track = row("t1")
        state.nextTracks = [row("t2"), row("t3"), delimiter]
            + ["t1", "t2", "t3"].map { row($0, hidden: nextIterationHidden) }
            + [delimiter]
        return state
    }

    private func uris(_ ids: String...) -> [String] {
        ids.map { "spotify:track:\($0)" }
    }

    @Test func `with repeat off, the queue ends with the context's last track`() {
        let queue = LibrespotClient.mirroredQueue(of: album(nextIterationHidden: true))

        #expect(queue.nextTracks.map(\.uri) == uris("t2", "t3"))
        #expect(queue.currentTrack?.uri == "spotify:track:t1")
        #expect(queue.currentTrack?.uid == "uid-t1")
        #expect(queue.context == "spotify:album:a")
    }

    @Test func `with repeat on, the next iteration shows, without its delimiters`() {
        let queue = LibrespotClient.mirroredQueue(of: album(nextIterationHidden: false))

        #expect(queue.nextTracks.map(\.uri) == uris("t2", "t3", "t1", "t2", "t3"))
    }

    @Test func `a hidden row before the current track is left out too`() {
        var state = PlayerState()
        state.track = row("t2")
        state.prevTracks = [row("t1"), delimiter]

        #expect(LibrespotClient.mirroredQueue(of: state).previousTracks.map(\.uri) == uris("t1"))
    }

    @Test func `the queue carries the name the cluster gives its context`() {
        var state = album(nextIterationHidden: true)
        state.contextMetadata = ["context_description": "Not Bad for New Jersey"]

        #expect(LibrespotClient.mirroredQueue(of: state).contextName == "Not Bad for New Jersey")
    }

    @Test func `an empty context description names nothing`() {
        var state = album(nextIterationHidden: true)
        state.contextMetadata = ["context_description": ""]

        #expect(LibrespotClient.mirroredQueue(of: state).contextName == nil)
    }
}

/// Whether another device lets Next be pressed, from its player state's restrictions.
struct SkipNextRestrictionTests {
    private func state(restrictions: [Int: String]) -> PlayerState {
        let data = ProtobufWriter.message { message in
            message.string(field: 2, "spotify:album:a")
            message.bytes(field: 17, ProtobufWriter.message { restriction in
                for (field, reason) in restrictions.sorted(by: { $0.key < $1.key }) {
                    restriction.string(field: field, reason)
                }
            })
        }
        return PlayerState.parse(from: data)
    }

    /// Measured on the web player, 2026-10-01: an album's last track with repeat off names
    /// reasons for other things, and none for Next.
    @Test func `other restrictions leave Next allowed`() {
        let remote = state(restrictions: [2: "not_paused", 6: "no_prev_track", 31: "no_sleep_timer_set"])

        #expect(!remote.disallowsSkippingNext)
        #expect(remote.contextUri == "spotify:album:a")
    }

    @Test func `a reason not to skip next disallows it`() {
        #expect(state(restrictions: [7: "no_next_track"]).disallowsSkippingNext)
    }
}
