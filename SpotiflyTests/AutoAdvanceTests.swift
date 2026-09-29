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
    /// A queue of uris, and which of them fail to load and how.
    private final class Player {
        let queue: [String]
        let failures: [String: any Error]
        var repeats = false
        private var position = 0
        private(set) var loaded: [String] = []
        private(set) var skipped: [String] = []

        init(_ queue: [String], failing failures: [String: any Error] = [:]) {
            self.queue = queue
            self.failures = failures
        }

        func advance(from index: Int) async -> AutoAdvance.Outcome {
            position = index
            return await AutoAdvance.run(
                from: queue[index],
                attempts: queue.count,
                load: { uri in
                    self.loaded.append(uri)
                    if let failure = self.failures[uri] {
                        throw failure
                    }
                },
                advance: {
                    if self.position + 1 < self.queue.count {
                        self.position += 1
                    } else if self.repeats {
                        self.position = 0
                    } else {
                        return nil
                    }
                    return self.queue[self.position]
                },
                skipped: { uri, _ in self.skipped.append(uri) },
            )
        }
    }

    private static let unavailable = LibrespotError.trackUnavailable(name: "Girlfriend (feat. Dâm-Funk)")

    @Test func `an unavailable track is skipped and the next one plays`() async {
        let player = Player(["a", "b", "c"], failing: ["b": Self.unavailable])

        let outcome = await player.advance(from: 1)

        #expect(outcome.kind == "playing")
        #expect(player.loaded == ["b", "c"])
        #expect(player.skipped == ["b"])
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
            let player = Player(["a", "b", "c"], failing: ["b": error])

            let outcome = await player.advance(from: 1)

            #expect(outcome.kind == "stopped")
            #expect(player.loaded == ["b"])
            #expect(player.skipped.isEmpty)
        }
    }

    /// Repeat wraps the queue, so nothing but the attempt count ends this.
    @Test func `under repeat, a queue of nothing but unavailable tracks stops after one pass`() async {
        let player = Player(["a", "b", "c"], failing: ["a": Self.unavailable, "b": Self.unavailable, "c": Self.unavailable])
        player.repeats = true

        let outcome = await player.advance(from: 0)

        #expect(outcome.kind == "stopped")
        #expect(player.loaded == ["a", "b", "c"])
        #expect(player.skipped == ["a", "b"])
    }

    @Test func `the queue running out while skipping is its end, not a failure`() async {
        let player = Player(["a", "b"], failing: ["b": Self.unavailable])

        let outcome = await player.advance(from: 1)

        #expect(outcome.kind == "queueEnded")
        #expect(player.skipped == ["b"])
    }

    @Test func `a newer load taking over is neither skipped nor a stop`() async {
        let player = Player(["a", "b"], failing: ["a": CancellationError()])

        let outcome = await player.advance(from: 0)

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
        let error = #expect(throws: LibrespotError.self) {
            try AudioPipeline.fileToPlay(self.metadata(name: "Girlfriend (feat. Dâm-Funk)", []), uri: "spotify:track:6PpbRUIbMyUbJkWHS3eQ8j", preferring: .normal)
        }
        guard case let .trackUnavailable(name)? = error else {
            Issue.record("expected trackUnavailable, got \(String(describing: error))")
            return
        }
        #expect(name == "Girlfriend (feat. Dâm-Funk)")
    }

    @Test func `an unavailable track without a name is named by its uri`() {
        let error = #expect(throws: LibrespotError.self) {
            try AudioPipeline.fileToPlay(self.metadata(name: "", []), uri: "spotify:track:x", preferring: .normal)
        }
        guard case let .trackUnavailable(name)? = error else {
            Issue.record("expected trackUnavailable, got \(String(describing: error))")
            return
        }
        #expect(name == "spotify:track:x")
    }

    /// Files this player does not decode are not Spotify withholding the track, so auto-advance
    /// does not skip it and the message does not claim so.
    @Test func `files in other formats only are not called unavailable`() {
        let error = #expect(throws: LibrespotError.self) {
            try AudioPipeline.fileToPlay(self.metadata([.mp3320, .aac48]), uri: "spotify:track:x", preferring: .normal)
        }
        guard case .trackNotFound? = error else {
            Issue.record("expected trackNotFound, got \(String(describing: error))")
            return
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
