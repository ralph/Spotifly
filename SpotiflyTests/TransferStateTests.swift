//
//  TransferStateTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// Reading the state another device hands over with a Connect `transfer`.
///
/// The inputs are built with `ProtobufWriter` from librespot's
/// `protocol/proto/transfer_state.proto` (and the playback, session, context,
/// context_page, context_track and queue messages it nests) — schema-built,
/// not captured from a real transfer.
struct TransferStateTests {
    private static func contextTrack(uri: String, uid: String? = nil) -> (inout ProtobufWriter) -> Void {
        {
            $0.string(field: 1, uri)
            if let uid {
                $0.string(field: 2, uid)
            }
        }
    }

    private static func transfer(
        paused: Bool = false,
        contextUri: String = "spotify:playlist:abc",
        rows: [(inout ProtobufWriter) -> Void] = [contextTrack(uri: "spotify:track:first"), contextTrack(uri: "spotify:track:current")],
        sessionUid: String = "uid-current",
        currentTrack: @escaping (inout ProtobufWriter) -> Void = contextTrack(uri: "spotify:track:current"),
        queue: [String] = [],
        playingQueue: Bool = false,
    ) -> Data {
        ProtobufWriter.message {
            $0.message(field: 1) { options in
                options.bool(field: 1, true)
                options.bool(field: 2, true)
            }
            $0.message(field: 2) { playback in
                playback.varint(field: 1, Int64(1_790_000_000_000))
                playback.varint(field: 2, Int32(61000))
                playback.double(field: 3, paused ? 0 : 1)
                playback.bool(field: 4, paused)
                playback.message(field: 5, currentTrack)
            }
            $0.message(field: 3) { session in
                session.message(field: 2) { context in
                    context.string(field: 1, contextUri)
                    context.message(field: 5) { page in
                        for row in rows {
                            page.message(field: 4, row)
                        }
                    }
                }
                session.string(field: 3, sessionUid)
            }
            $0.message(field: 4) { queued in
                for uri in queue {
                    queued.message(field: 1, contextTrack(uri: uri))
                }
                queued.bool(field: 2, playingQueue)
            }
        }
    }

    @Test func `the context, track, options and position come through`() {
        let state = TransferState(parsing: Self.transfer())

        #expect(state.contextUri == "spotify:playlist:abc")
        #expect(state.contextTrackUris == ["spotify:track:first", "spotify:track:current"])
        #expect(state.currentTrackUri == "spotify:track:current")
        #expect(state.shuffle)
        #expect(state.repeatContext)
        #expect(!state.repeatTrack)
        #expect(!state.isPaused)
        #expect(state.positionAsOfTimestamp == 61000)
    }

    /// librespot's `handle_transfer`: a track that kept playing on the sender moved on by
    /// however long ago the position was taken; a paused one did not.
    @Test func `a playing track is carried forward and a paused one is not`() {
        let playing = TransferState(parsing: Self.transfer())
        let paused = TransferState(parsing: Self.transfer(paused: true))

        #expect(playing.position(atMs: 1_790_000_002_500) == 63500)
        #expect(paused.position(atMs: 1_790_000_002_500) == 61000)
    }

    /// A sender reports its position when something changes, so a track played from its
    /// start arrives as 0 at the moment it started. It has still been playing since.
    @Test func `a position reported as zero is carried forward too`() {
        var state = TransferState(parsing: Self.transfer())
        state.positionAsOfTimestamp = 0

        #expect(state.position(atMs: 1_790_000_048_000) == 48000)
    }

    @Test func `the current track's uid comes through, and not a queued track's`() {
        let track = Self.contextTrack(uri: "spotify:track:current", uid: "uid-current")

        #expect(TransferState(parsing: Self.transfer(currentTrack: track)).currentTrackUid == "uid-current")
        let fromQueue = TransferState(parsing: Self.transfer(currentTrack: track, queue: ["spotify:track:q1"], playingQueue: true))
        #expect(fromQueue.currentTrackUid == nil)
    }

    /// The session's `current_uid` names the context row that plays after a queued track, and
    /// only the current track again while a context track plays.
    @Test func `playing from the queue, the session's uid names where the context goes on`() {
        let fromQueue = TransferState(parsing: Self.transfer(queue: ["spotify:track:q1"], playingQueue: true))
        #expect(fromQueue.contextResumeUid == "uid-current")

        let fromContext = TransferState(parsing: Self.transfer(queue: ["spotify:track:q1"]))
        #expect(fromContext.contextResumeUid == nil)
    }

    @Test func `a list's rows keep their uids beside them, and a row without a track is left out`() {
        let state = TransferState(parsing: Self.transfer(contextUri: "-", rows: [
            Self.contextTrack(uri: "spotify:track:a", uid: "uid-a"),
            { $0.string(field: 2, "uid-nothing") },
            Self.contextTrack(uri: "spotify:track:b"),
        ]))

        #expect(state.contextUri == "")
        #expect(state.contextTrackUris == ["spotify:track:a", "spotify:track:b"])
        #expect(state.contextTrackUids == ["uid-a", nil])
    }

    /// Measured with a phone (2026-10-02): a bare list handed over while a queued track played
    /// came whole, each row with a uid, and the session's uid named the row after the one the
    /// phone had played. `PlaybackQueue.start(in:queued:resumingAt:uids:)` places it from those.
    @Test func `a bare list handed over from the queue names the row it goes on with`() {
        let state = TransferState(parsing: Self.transfer(
            contextUri: "",
            rows: (0 ..< 4).map { Self.contextTrack(uri: "spotify:track:t\($0)", uid: "u\($0)") },
            sessionUid: "u2",
            queue: ["spotify:track:q1"],
            playingQueue: true,
        ))

        #expect(state.currentTrackUri == "spotify:track:q1")
        #expect(state.contextTrackUids == ["u0", "u1", "u2", "u3"])
        #expect(state.contextResumeUid == "u2")
    }

    @Test func `a track sent only by gid gets its uri back`() {
        // spotify:track:6rqhFgbbKwnb9MLmUQDhG6 is gid d3aca7e43e3b452cbfa9ddd2eab9497e,
        // by base-62 decoding in Python.
        let gid = Data([0xD3, 0xAC, 0xA7, 0xE4, 0x3E, 0x3B, 0x45, 0x2C, 0xBF, 0xA9, 0xDD, 0xD2, 0xEA, 0xB9, 0x49, 0x7E])
        let state = TransferState(parsing: Self.transfer(currentTrack: { $0.bytes(field: 3, gid) }))

        #expect(state.currentTrackUri == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
    }

    @Test func `queued tracks are kept, and playing from the queue makes its head current`() {
        let fromContext = TransferState(parsing: Self.transfer(queue: ["spotify:track:q1", "spotify:track:q2"]))
        #expect(fromContext.currentTrackUri == "spotify:track:current")
        #expect(fromContext.queuedTrackUris == ["spotify:track:q1", "spotify:track:q2"])

        let fromQueue = TransferState(parsing: Self.transfer(queue: ["spotify:track:q1", "spotify:track:q2"], playingQueue: true))
        #expect(fromQueue.currentTrackUri == "spotify:track:q1")
        #expect(fromQueue.queuedTrackUris == ["spotify:track:q2"])
    }

    @Test func `a transfer command carries its state`() {
        let json: [String: Any] = ["endpoint": "transfer", "data": Self.transfer().base64EncodedString()]

        guard case let .transfer(state) = DealerConnection.parseCommand(endpoint: "transfer", json: json) else {
            Issue.record("not parsed as a transfer")
            return
        }
        #expect(state.currentTrackUri == "spotify:track:current")
    }

    @Test func `a transfer without data is not mistaken for one`() {
        guard case .unknown = DealerConnection.parseCommand(endpoint: "transfer", json: ["endpoint": "transfer"]) else {
            Issue.record("a transfer without data must not start anything")
            return
        }
    }
}

/// The token other clients key their cached copy of this device's queue on.
struct QueueRevisionTests {
    @Test func `the revision is stable for the same queue and moves when it changes`() {
        let queue = ["spotify:track:a", "spotify:track:b"]

        #expect(SpircController.queueRevision(of: queue) == SpircController.queueRevision(of: queue))
        #expect(SpircController.queueRevision(of: queue) != SpircController.queueRevision(of: queue.reversed()))
        #expect(SpircController.queueRevision(of: queue) != SpircController.queueRevision(of: Array(queue.dropFirst())))
    }

    @Test func `track boundaries count, not just the characters`() {
        #expect(SpircController.queueRevision(of: ["ab", "c"]) != SpircController.queueRevision(of: ["a", "bc"]))
    }
}
