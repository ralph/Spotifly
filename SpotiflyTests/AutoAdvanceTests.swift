//
//  AutoAdvanceTests.swift
//  SpotiflyTests
//
//  What happens when auto-advance reaches a track that cannot play.
//

import Foundation
@testable import Spotifly
import Testing

/// The rule `LibrespotClient` follows at the end of a track, run against a stand-in queue.
struct AutoAdvanceTests {
    /// The client's queue, and which of its tracks fail to load and how.
    private final class Player {
        let queue = PlaybackQueue()
        let failures: [String: any Error]
        /// Known not to play, as the app's lists would have said.
        var unplayable: Set<String> = []
        private(set) var loaded: [String] = []
        private(set) var skipped: [String] = []
        private(set) var skippedNames: [String] = []

        init(_ tracks: [String], startingAt index: Int = 0, failing failures: [String: any Error] = [:]) {
            queue.setContext(uri: "spotify:playlist:test", tracks: tracks, startIndex: index)
            self.failures = failures
        }

        /// The end of the current track: what `handleEndOfTrack` does before the run.
        func endOfTrack() -> String? {
            queue.advance()
        }

        func autoAdvance() async -> AutoAdvance.Outcome {
            await AutoAdvance.run(
                from: queue.currentUri ?? "",
                in: queue,
                isUnplayable: unplayable.contains,
                load: { uri in
                    self.loaded.append(uri)
                    if let failure = self.failures[uri] {
                        throw failure
                    }
                },
                skipped: { uri, name in
                    self.skipped.append(uri)
                    self.skippedNames.append(name)
                },
            )
        }
    }

    private static let unavailable = LibrespotError.trackUnavailable(name: "Girlfriend (feat. Dâm-Funk)")

    @Test func `an unavailable track is skipped and the next one plays`() async {
        let player = Player(["a", "b", "c"], startingAt: 1, failing: ["b": Self.unavailable])

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "playing")
        #expect(player.loaded == ["b", "c"])
        #expect(player.skipped == ["b"])
        #expect(player.skippedNames == ["Girlfriend (feat. Dâm-Funk)"])
    }

    /// The plan's rule: a skip must mean the track cannot play, never that the network
    /// blinked. `trackNotFound` is what any failed metadata request throws, a 5xx included.
    @Test func `a network error or a failed request stops instead of skipping`() async {
        let errors: [any Error] = [
            URLError(.notConnectedToInternet),
            LibrespotError.trackNotFound("e0624580e17b49bab335775ea6fe1593"),
            LibrespotError.audioKeyFailed("timeout"),
        ]
        for error in errors {
            let player = Player(["a", "b", "c"], startingAt: 1, failing: ["b": error])

            let outcome = await player.autoAdvance()

            #expect(outcome.kind == "stopped")
            #expect(player.loaded == ["b"])
            #expect(player.skipped.isEmpty)
        }
    }

    /// Repeat wraps the queue, so nothing but the attempt count ends this.
    @Test func `under repeat, a queue of nothing but unavailable tracks stops after one pass`() async {
        let player = Player(["a", "b", "c"], failing: ["a": Self.unavailable, "b": Self.unavailable, "c": Self.unavailable])
        player.queue.setRepeat(.context)

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "stopped")
        #expect(player.loaded == ["a", "b", "c"])
        #expect(player.skipped == ["a", "b"])
    }

    /// Found in review. The track the run starts from had already left the user queue when the
    /// attempts were counted, so the run gave up one track short: here, before wrapping round to
    /// the one track that plays.
    @Test func `a queued track the run starts from counts as an attempt of its own`() async {
        let player = Player(["c", "u1", "u2"], failing: ["q": Self.unavailable, "u1": Self.unavailable, "u2": Self.unavailable])
        player.queue.setRepeat(.context)
        player.queue.enqueue("q")
        #expect(player.endOfTrack() == "q")

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "playing")
        #expect(player.loaded == ["q", "u1", "u2", "c"])
        #expect(player.skipped == ["q", "u1", "u2"])
    }

    @Test func `the queue running out while skipping is its end, not a failure`() async {
        let player = Player(["a", "b"], startingAt: 1, failing: ["b": Self.unavailable])

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "queueEnded")
        #expect(player.skipped == ["b"])
    }

    /// Its row is greyed out already, so it is passed over without a load or a word.
    @Test func `a track known not to play is stepped over without loading it`() async {
        let player = Player(["a", "b", "c", "d"], startingAt: 1)
        player.unplayable = ["b", "c"]

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "playing")
        #expect(player.loaded == ["d"])
        #expect(player.skipped.isEmpty)
        #expect(player.queue.currentUri == "d")
    }

    @Test func `a known one after a track that failed to load is stepped over too`() async {
        let player = Player(["a", "b", "c", "d"], startingAt: 1, failing: ["b": Self.unavailable])
        player.unplayable = ["c"]

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "playing")
        #expect(player.loaded == ["b", "d"])
        #expect(player.skipped == ["b"])
    }

    /// Nothing is loaded, so nothing names the stop; the client rewinds the context, whose
    /// first load then fails with the track's name.
    @Test func `under repeat, a queue known to be all unplayable ends after one pass`() async {
        let player = Player(["a", "b", "c"])
        player.queue.setRepeat(.context)
        player.unplayable = ["a", "b", "c"]

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "queueEnded")
        #expect(player.loaded.isEmpty)
    }

    /// Next and Previous step the same way, each with its own move.
    @Test func `stepping backward passes over known ones in the history`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:test", tracks: ["a", "b", "c", "d"], startIndex: 0)
        for _ in 0 ..< 3 {
            _ = queue.advance()
        }
        let unplayable: Set = ["c", "b"]

        let previous = queue.move(by: queue.backward, skipping: unplayable.contains)

        #expect(previous == "a")
        #expect(queue.currentUri == "a")
    }

    @Test func `a newer load taking over is neither skipped nor a stop`() async {
        let player = Player(["a", "b"], failing: ["a": CancellationError()])

        let outcome = await player.autoAdvance()

        #expect(outcome.kind == "superseded")
        #expect(player.skipped.isEmpty)
    }
}

/// Which file a track plays from, and what it means when there is none.
struct TrackFileChoiceTests {
    private func metadata(name: String = "Song", _ formats: [SPClient.TrackMetadata.AudioFormat]) -> SPClient.TrackMetadata {
        SPClient.TrackMetadata(
            gid: Data(),
            name: name,
            durationMs: 201_073,
            files: formats.enumerated().map { .init(fileId: Data([UInt8($0.offset)]), format: $0.element) },
        )
    }

    /// "Girlfriend" on 2026-09-29: `restriction { countries_allowed: "" }`, no files, no
    /// alternative. It used to fail as "Track not found: No Ogg Vorbis file available".
    @Test func `a track with no file at all is unavailable, and named`() {
        #expect(throws: LibrespotError.trackUnavailable(name: "Girlfriend (feat. Dâm-Funk)")) {
            try AudioPipeline.fileToPlay(self.metadata(name: "Girlfriend (feat. Dâm-Funk)", []), uri: "spotify:track:6PpbRUIbMyUbJkWHS3eQ8j", preferring: .normal)
        }
    }

    @Test func `an unavailable track without a name is named by its uri`() {
        #expect(throws: LibrespotError.trackUnavailable(name: "spotify:track:x")) {
            try AudioPipeline.fileToPlay(self.metadata(name: "", []), uri: "spotify:track:x", preferring: .normal)
        }
    }

    /// Files this player does not decode are not Spotify withholding the track, so auto-advance
    /// does not skip it and the message does not claim so. `.unknown` is how the extended-metadata
    /// answer hands on a format `AudioFormat` does not name, when it is all there is.
    @Test func `files in other formats only are not called unavailable`() {
        #expect(throws: LibrespotError.trackNotFound("No Ogg Vorbis file available")) {
            try AudioPipeline.fileToPlay(self.metadata([.mp3320, .aac48, .unknown]), uri: "spotify:track:x", preferring: .normal)
        }
    }

    @Test func `the nearest Vorbis quality wins`() throws {
        let track = metadata([.mp3320, .oggVorbis96, .oggVorbis320])

        #expect(try AudioPipeline.fileToPlay(track, uri: "", preferring: .high).format == .oggVorbis320)
        #expect(try AudioPipeline.fileToPlay(track, uri: "", preferring: .low).format == .oggVorbis96)
        #expect(try AudioPipeline.fileToPlay(metadata([.oggVorbis96, .oggVorbis320]), uri: "", preferring: .normal).format == .oggVorbis96)
    }
}

extension AutoAdvance.Outcome {
    /// The case without its error, to compare in expectations.
    var kind: String {
        switch self {
        case .playing: "playing"
        case .queueEnded: "queueEnded"
        case .superseded: "superseded"
        case .stopped: "stopped"
        }
    }
}
