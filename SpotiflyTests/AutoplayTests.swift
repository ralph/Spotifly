//
//  AutoplayTests.swift
//  SpotiflyTests
//
//  Autoplay after a context ends: the account's setting, the station asked for, and the rows
//  lined up after the context's own. See `plans/open/autoplay.md`. The take-over of another
//  device's autoplay is in `MirroredQueueTests` and `TransferStateTests`.
//

import Foundation
@testable import Spotifly
import Testing

struct AutoplaySettingTests {
    @Test func `the login names the account's autoplay setting`() {
        let payload = Data("<products><product><type>premium</type><autoplay>1</autoplay></product></products>".utf8)

        #expect(Accesspoint.attribute("autoplay", inProductInfo: payload) == "1")
        #expect(Accesspoint.attribute("ads", inProductInfo: payload) == nil)
    }

    /// Captured 2026-10-02, autoplay switched off on a phone: one field naming `autoplay`, and a
    /// timestamp.
    @Test func `a mutation names the attributes it changed`() throws {
        let payload = try #require(Data(base64Encoded: "CgoKCGF1dG9wbGF5EgwIt7391QYQhPfBjQM="))

        #expect(DealerConnection.mutatedAttributes(in: payload) == ["autoplay"])
    }
}

@MainActor
struct AutoplayRequestTests {
    @Test func `the station is asked for with the context and its tracks, and answered as a resolve`() async throws {
        let sent = Recorder<URLRequest>()
        let answer = Data(#"{"uri":"spotify:station:album:a","pages":[{"tracks":[{"uri":"spotify:track:s1","uid":"x1"},{"uri":"spotify:track:s2","uid":"x2"}]}]}"#.utf8)
        let credentials = spotifyCredentials(transport: { request in
            sent.record(request)
            return (answer, httpResponse(200, url: request.url!))
        })
        let client = SPClient(credentials: credentials, deviceId: "device")

        let station = try await client.resolveAutoplay(contextUri: "spotify:album:a", recentTrackUris: ["spotify:track:1"])

        #expect(station.tracks == ["spotify:track:s1", "spotify:track:s2"])
        #expect(station.uids == ["x1", "x2"])
        let request = try #require(sent.values.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/context-resolve/v1/autoplay")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        // `AutoplayContextRequest`: the context, then the tracks it played.
        let fields = try ProtobufReader.fields(in: #require(request.httpBody))
        #expect(fields.filter { $0.number == 1 }.map(\.string) == ["spotify:album:a"])
        #expect(fields.filter { $0.number == 2 }.map(\.string) == ["spotify:track:1"])
    }

    @Test func `an autoplay row says so to other devices`() {
        #expect(SpircController.provided(uri: "spotify:track:a", uid: "u", provider: "autoplay").metadata["autoplay.is_autoplay"] == "true")
        #expect(SpircController.provided(uri: "spotify:track:a", uid: nil, provider: "context").metadata.isEmpty)
    }
}

struct AutoplayQueueTests {
    private func album(at index: Int = 2) -> PlaybackQueue {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a1", "a2", "a3"], startIndex: index)
        return queue
    }

    /// The context stays the album, the rows say autoplay, as a phone reports its own.
    @Test func `autoplay's rows follow the context's, and it plays on into them`() {
        let queue = album()
        queue.appendAutoplay(["s1", "s2"], uids: ["x1", "x2"])

        #expect(queue.upcoming().map(\.uri) == ["s1", "s2"])
        #expect(queue.upcoming().map(\.provider) == ["autoplay", "autoplay"])
        #expect(queue.currentProvider == "context")

        #expect(queue.advance() == "s1")
        #expect(queue.currentProvider == "autoplay")
        #expect(queue.contextUri == "spotify:album:a")
        // Previous goes back into the album.
        #expect(queue.history == ["a3"])
    }

    @Test func `autoplay is asked for once per context, and again once its rows are gone`() {
        let queue = album()
        queue.markAutoplayAsked()
        queue.appendAutoplay(["s1"], uids: [nil])
        #expect(queue.autoplayAsked)

        queue.dropAutoplay()
        #expect(!queue.autoplayAsked)
        #expect(queue.upcoming().isEmpty)

        // The same album again is another context.
        queue.markAutoplayAsked()
        queue.setContext(uri: "spotify:album:a", tracks: ["a1", "a2", "a3"], startIndex: 2)
        #expect(!queue.autoplayAsked)
    }

    @Test func `repeat takes autoplay's rows away while the context's own plays`() {
        let queue = album()
        queue.appendAutoplay(["s1"], uids: [nil])
        queue.setRepeat(.context)

        #expect(queue.autoplayStart == nil)
        #expect(!queue.upcoming(rounds: .asPlayed).contains { $0.provider == "autoplay" })
    }

    /// Repeat switched on while an autoplay row plays: the station plays out, then the context's
    /// own rows come round again, without it.
    @Test func `repeat during autoplay goes round the context's own rows`() {
        let queue = album()
        queue.appendAutoplay(["s1", "s2"], uids: [nil, nil])
        _ = queue.advance()
        queue.setRepeat(.context)

        #expect(queue.autoplayStart == 3)
        #expect(queue.upcoming(limit: 5, rounds: .asPlayed).map(\.uri) == ["s2", "a1", "a2", "a3", "a1"])
        #expect(queue.advance() == "s2")
        #expect(queue.advance() == "a1")
        #expect(queue.autoplayStart == nil)
        // The station's rows left the history with it, which listed past the context's end.
        #expect(queue.history == ["a3"])
        #expect(queue.recent().map(\.uri) == ["a3"])
    }

    @Test func `switched off, the rows stay while one plays`() {
        let queue = album()
        queue.appendAutoplay(["s1"], uids: [nil])
        _ = queue.advance()
        queue.dropAutoplay()

        #expect(queue.currentUri == "s1")
        #expect(queue.autoplayStart == 3)
    }

    @Test func `a rewind after autoplay starts the context over without it`() {
        let queue = album()
        queue.appendAutoplay(["s1"], uids: [nil])
        _ = queue.advance()
        queue.rewind(to: 0)

        #expect(queue.contextTracks == ["a1", "a2", "a3"])
        #expect(queue.autoplayStart == nil)
    }

    @Test func `shuffled, autoplay's rows come after the context's, and go on in order`() {
        let queue = album(at: 0)
        queue.setShuffle(true)
        while !queue.upcoming().isEmpty {
            _ = queue.advance()
        }
        queue.appendAutoplay(["s1", "s2", "s3"], uids: [nil, nil, nil])
        #expect(queue.upcoming().map(\.uri) == ["s1", "s2", "s3"])

        // Shuffle switched on again during autoplay goes on with the rest of it.
        _ = queue.advance()
        queue.setShuffle(false)
        queue.setShuffle(true)
        #expect(queue.upcoming().map(\.uri) == ["s2", "s3"])
    }

    @Test func `an album's uids, adopted late, name its own rows and leave autoplay's`() {
        let queue = album()
        queue.appendAutoplay(["s1"], uids: ["x1"])

        #expect(queue.adoptRowUids([("a1", "u1"), ("a2", "u2"), ("a3", "u3")], ofContext: "spotify:album:a"))
        #expect(queue.upcoming().first?.uid == "x1")
        #expect(queue.current?.uid == "u3")
    }

    @Test func `the seed is the context's own tracks, its last 50`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:playlist:p", tracks: (0 ..< 60).map { "t\($0)" }, startIndex: 59)
        queue.appendAutoplay(["s1"], uids: [nil])

        #expect(queue.autoplaySeed == (10 ..< 60).map { "t\($0)" })
    }

    /// As `playQueued` takes over a queued track: the context's row it stood on goes into the
    /// history.
    @Test func `a take-over plays another device's autoplay after the context's last row`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: ["a1", "a2"], startIndex: 1)
        queue.playAutoplay(["s1", "s2"], uids: ["x1", "x2"])

        #expect(queue.currentUri == "s1")
        #expect(queue.currentProvider == "autoplay")
        #expect(queue.history == ["a2"])
        #expect(queue.upcoming().map(\.uri) == ["s2"])
        #expect(queue.autoplayAsked)
    }

    @Test func `with no context to stand on, autoplay's first row plays`() {
        let queue = PlaybackQueue()
        queue.setContext(uri: "spotify:album:a", tracks: [], startIndex: 0)
        queue.playAutoplay(["s1", "s2"], uids: [nil, nil])

        #expect(queue.currentUri == "s1")
        #expect(queue.history.isEmpty)
    }
}
