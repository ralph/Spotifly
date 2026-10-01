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

/// A bare list another device plays, as this Mac takes it over.
struct BareListTakeOverTests {
    private func row(_ id: String, provider: String = "context", hidden: Bool = false) -> ProvidedTrack {
        var track = ProvidedTrack(uri: "spotify:track:\(id)", provider: provider)
        track.metadata = hidden ? ["hidden": "true"] : [:]
        return track
    }

    private let delimiter: ProvidedTrack = {
        var track = ProvidedTrack(uri: "spotify:delimiter")
        track.metadata = ["hidden": "true"]
        return track
    }()

    private func uris(_ ids: String...) -> [String] {
        ids.map { "spotify:track:\($0)" }
    }

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

    @Test func `queued rows go to the queue, not into the list`() throws {
        var state = PlayerState()
        state.track = row("t1")
        state.nextTracks = [row("q", provider: "queue"), row("t2"), delimiter, row("t1", hidden: true)]

        let list = try #require(LibrespotClient.takeOverList(of: state))

        #expect(list.tracks == uris("t1", "t2"))
        #expect(list.index == 0)
        #expect(list.queued == uris("q"))
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
