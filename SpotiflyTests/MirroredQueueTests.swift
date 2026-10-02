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
    private func row(_ id: String, provider: String = "context", hidden: Bool = false) -> ProvidedTrack {
        var track = ProvidedTrack(uri: "spotify:track:\(id)", uid: "uid-\(id)", provider: provider)
        track.metadata = hidden ? ["hidden": "true"] : [:]
        return track
    }

    private let delimiter: ProvidedTrack = {
        var track = ProvidedTrack(uri: "spotify:delimiter")
        track.metadata = ["hidden": "true"]
        return track
    }()

    /// The shape the web player sent on 2026-09-30 for an album: its rows, a delimiter, then
    /// the album again as the next iteration, hidden unless repeat is on.
    private func album(repeating: Bool) -> PlayerState {
        var state = PlayerState()
        state.contextUri = "spotify:album:a"
        state.track = row("t1")
        state.options.repeatingContext = repeating
        state.nextTracks = [row("t2"), row("t3"), delimiter]
            + ["t1", "t2", "t3"].map { row($0, hidden: !repeating) }
            + [delimiter]
        return state
    }

    private func uris(_ ids: String...) -> [String] {
        ids.map { "spotify:track:\($0)" }
    }

    @Test func `with repeat off, the queue ends with the context's last track`() {
        let queue = LibrespotClient.mirroredQueue(of: album(repeating: false))

        #expect(queue.nextTracks.map(\.uri) == uris("t2", "t3"))
        #expect(queue.currentTrack?.uri == "spotify:track:t1")
        #expect(queue.currentTrack?.uid == "uid-t1")
        #expect(queue.context == "spotify:album:a")
    }

    /// As this Mac's own queue lists one round, and the web player's queue panel does.
    @Test func `with repeat on, one round shows, up to the first delimiter`() {
        let queue = LibrespotClient.mirroredQueue(of: album(repeating: true))

        #expect(queue.nextTracks.map(\.uri) == uris("t2", "t3"))
    }

    /// librespot lists autoplay after a delimiter, which may not be hidden; unmeasured.
    @Test func `rows after a delimiter that are not the context stay`() {
        var state = album(repeating: false)
        state.nextTracks = [row("t2"), row("t3"), delimiter, row("a1", provider: "autoplay")]

        #expect(LibrespotClient.mirroredQueue(of: state).nextTracks.map(\.uri) == uris("t2", "t3", "a1"))
    }

    /// Whatever the options say: how a device encodes repeat-one is unmeasured.
    @Test func `the context again after a delimiter is left out, whatever the options say`() {
        var state = album(repeating: true)
        state.options.repeatingContext = false

        #expect(LibrespotClient.mirroredQueue(of: state).nextTracks.map(\.uri) == uris("t2", "t3"))
    }

    @Test func `a hidden row before the current track is left out too`() {
        var state = PlayerState()
        state.track = row("t2")
        state.prevTracks = [row("t1"), delimiter]

        #expect(LibrespotClient.mirroredQueue(of: state).previousTracks.map(\.uri) == uris("t1"))
    }

    @Test func `the queue carries the name the cluster gives its context`() {
        var state = album(repeating: false)
        state.contextMetadata = ["context_description": "Not Bad for New Jersey"]

        #expect(LibrespotClient.mirroredQueue(of: state).contextName == "Not Bad for New Jersey")
    }

    @Test func `an empty context description names nothing`() {
        var state = album(repeating: false)
        state.contextMetadata = ["context_description": ""]

        #expect(LibrespotClient.mirroredQueue(of: state).contextName == nil)
    }
}

/// A bare list another device plays, as this Mac takes it over.
extension MirroredQueueTests {
    /// With repeat on, the list goes on after a delimiter as its next iteration. Taken whole, it
    /// held its tracks twice, and local repeat looped that.
    @Test func `the list stops at the first delimiter, and starts with the tracks before`() throws {
        var state = PlayerState()
        state.prevTracks = [row("t1")]
        state.track = row("t2")
        state.nextTracks = [row("t3"), delimiter, row("t1"), row("t2"), row("t3"), delimiter]

        let list = try #require(LibrespotClient.takeOverList(of: state))

        #expect(list.tracks == uris("t1", "t2", "t3"))
        #expect(list.index == 1)
        #expect(list.queued.isEmpty)
    }

    /// Should a device keep the iteration before in its previous tracks, behind a delimiter.
    @Test func `the tracks before stop at the last delimiter behind`() throws {
        var state = PlayerState()
        state.prevTracks = [row("t1"), row("t2"), delimiter, row("t1")]
        state.track = row("t2")

        let list = try #require(LibrespotClient.takeOverList(of: state))

        #expect(list.tracks == uris("t1", "t2"))
        #expect(list.index == 1)
    }

    @Test func `queued rows go to the queue, not into the list`() throws {
        var state = PlayerState()
        state.track = row("t1")
        state.nextTracks = [row("q", provider: "queue"), row("t2"), delimiter, row("t1", hidden: true)]

        let list = try #require(LibrespotClient.takeOverList(of: state))

        #expect(list.tracks == uris("t1", "t2"))
        #expect(list.index == 0)
        #expect(list.queued == uris("q"))
    }

    /// What a handover of the same state does: the queued track plays as queued, not as one of
    /// the list's rows for repeat to play again, and the list goes on with the row after it.
    /// `PlaybackQueueTests` has the placement from `resumingAt`.
    @Test func `a queued track playing is left out of the list, which goes on at the row after it`() throws {
        var state = PlayerState()
        state.prevTracks = [row("t1"), row("q0", provider: "queue")]
        state.track = row("q1", provider: "queue")
        state.nextTracks = [row("q2", provider: "queue"), row("t2"), row("t3")]

        let list = try #require(LibrespotClient.takeOverList(of: state))
        #expect(list.tracks == uris("t1", "t2", "t3"))
        #expect(list.uids == ["uid-t1", "uid-t2", "uid-t3"])
        #expect(list.queued == uris("q2"))
        #expect(list.resumingAt == "uid-t2")
    }

    /// Nothing ahead to go on with: the queued track is played where it is, as a row.
    @Test func `a queued track at the list's end goes into the list`() throws {
        var state = PlayerState()
        state.prevTracks = [row("t1")]
        state.track = row("q1", provider: "queue")

        let list = try #require(LibrespotClient.takeOverList(of: state))
        #expect(list.tracks == uris("t1", "q1"))
        #expect(list.index == 1)
        #expect(list.resumingAt == nil)
    }

    @Test func `without a delimiter the list is every row after the current one`() throws {
        var state = PlayerState()
        state.track = row("t1")
        state.nextTracks = [row("t2"), row("t3")]

        #expect(try #require(LibrespotClient.takeOverList(of: state)).tracks == uris("t1", "t2", "t3"))
    }

    @Test func `nothing playing is nothing to take over`() {
        #expect(LibrespotClient.takeOverList(of: PlayerState()) == nil)
    }
}
