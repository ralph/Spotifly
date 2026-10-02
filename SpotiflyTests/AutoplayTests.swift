//
//  AutoplayTests.swift
//  SpotiflyTests
//
//  Autoplay after a context ends: the account's setting, the station asked for, and the rows
//  lined up after the context's own. See `plans/done/autoplay.md`. The take-over of another
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
        #expect(station.uri == "spotify:station:album:a")
        let request = try #require(sent.values.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/context-resolve/v1/autoplay")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-protobuf")
        // `AutoplayContextRequest`: the context, then the tracks it played.
        let fields = try ProtobufReader.fields(in: #require(request.httpBody))
        #expect(fields.filter { $0.number == 1 }.map(\.string) == ["spotify:album:a"])
        #expect(fields.filter { $0.number == 2 }.map(\.string) == ["spotify:track:1"])
    }

    /// As a phone's autoplay rows read (2026-10-02), and librespot's.
    @Test func `an autoplay row says so to other devices, with its station`() {
        let row = SpircController.provided(uri: "spotify:track:a", uid: "u", provider: "autoplay", station: "spotify:station:album:a")

        #expect(row.metadata == [
            "autoplay.is_autoplay": "true",
            "context_uri": "spotify:station:album:a",
            "entity_uri": "spotify:station:album:a",
        ])
        #expect(SpircController.provided(uri: "spotify:track:a", uid: nil, provider: "context", context: "spotify:album:a").metadata == [
            "context_uri": "spotify:album:a",
            "entity_uri": "spotify:album:a",
        ])
        #expect(SpircController.provided(uri: "spotify:track:a", uid: "q0", provider: "queue").metadata == ["is_queued": "true"])
        // A bare list names no context, and a delimiter belongs to none.
        #expect(SpircController.provided(uri: "spotify:track:a", uid: nil, provider: "context").metadata.isEmpty)
        #expect(SpircController.provided(uri: PlaybackQueue.delimiterUri, uid: "delimiter0", provider: "context", context: "spotify:album:a").metadata.isEmpty)
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

        #expect(queue.reportedIndex == 2)
        #expect(queue.advance() == "s1")
        #expect(queue.currentProvider == "autoplay")
        #expect(queue.contextUri == "spotify:album:a")
        // Not "row 3 of an album of three": other devices are told no row.
        #expect(queue.reportedIndex == nil)
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

    @Test func `the station goes with autoplay's rows`() {
        let queue = album()
        queue.appendAutoplay(["s1"], uids: [nil], from: "spotify:station:album:a")
        #expect(queue.autoplayContextUri == "spotify:station:album:a")

        queue.dropAutoplay()
        #expect(queue.autoplayContextUri == nil)
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

    /// Another device's queued track during its autoplay, taken over: it plays as queued, after the
    /// album's last row, and autoplay goes on after it from the first of the rows.
    @Test(arguments: [false, true])
    func `a queued track taken over plays before autoplay's rows`(shuffled: Bool) {
        let queue = album()
        queue.setShuffle(shuffled)
        queue.playAutoplay(["s2", "s3"], uids: ["x2", "x3"], after: "q0")

        #expect(queue.currentUri == "q0")
        #expect(queue.currentProvider == "queue")
        #expect(queue.history == ["a3"])
        #expect(queue.autoplayAsked)
        #expect(queue.sessionRow == QueueItem(uri: "s2", provider: "autoplay", uid: "x2"))
        #expect(queue.advance() == "s2")
        #expect(queue.currentProvider == "autoplay")
        #expect(queue.advance() == "s3")
    }

    /// What a handover names as the session's row: the track's, or after a queued track, the row
    /// the context goes on with, however many tracks are queued.
    @Test func `the session stands on the current row, or after a queued track on the next`() {
        let queue = album(at: 0)
        #expect(queue.sessionRow?.uri == "a1")

        queue.enqueue("q1")
        #expect(queue.advance() == "q1")
        #expect(queue.sessionRow?.uri == "a2")
        #expect(queue.sessionRow?.provider == "context")

        let autoplay = album()
        autoplay.appendAutoplay(["s1", "s2"], uids: ["x1", "x2"])
        #expect(autoplay.advance() == "s1")
        #expect(autoplay.sessionRow == QueueItem(uri: "s1", provider: "autoplay", uid: "x1"))
        for index in 0 ..< 60 {
            autoplay.enqueue("q\(index)")
        }
        #expect(autoplay.advance() == "q0")
        #expect(autoplay.sessionRow == QueueItem(uri: "s2", provider: "autoplay", uid: "x2"))
    }
}

/// What this Mac writes as its `transfer_data` while autoplay plays, which the backend hands the
/// device taking over. See `plans/done/phone-takes-macs-autoplay-as-queued.md`.
struct AutoplayHandoverTests {
    private static let autoplayRow = QueueItem(uri: "spotify:track:s1", provider: "autoplay", uid: "x1")
    private static let nextAutoplayRow = QueueItem(uri: "spotify:track:s2", provider: "autoplay", uid: "x2")

    /// The moment of the report, 5 s after the player state's.
    private static let now: Int64 = 1_790_000_005_000

    private func state(
        provider: String,
        paused: Bool = true,
        uid: String? = "x1",
        sessionRow: QueueItem? = autoplayRow,
        next: [QueueItem] = [nextAutoplayRow],
        station: String? = "spotify:station:album:a",
    ) -> SpircController.SpircPlayerState {
        SpircController.SpircPlayerState(
            isPlaying: true,
            isPaused: paused,
            trackUri: "spotify:track:s1",
            positionMs: 12000,
            durationMs: 200_000,
            shuffle: false,
            repeatMode: .off,
            timestamp: 1_790_000_000_000,
            contextUri: "spotify:album:a",
            contextMetadata: ["context_description": "Album A"],
            autoplayContextUri: station,
            trackProvider: provider,
            trackUid: uid,
            sessionRow: sessionRow,
            nextTracks: next,
            previousTracks: [],
        )
    }

    /// As the web player wrote it after taking this Mac's autoplay over (2026-10-02).
    @Test func `an autoplay track is handed over as its station, after the context it followed`() throws {
        let handover = try #require(SpircController.handover(of: state(provider: "autoplay"), atMs: Self.now))
        let read = TransferState(parsing: handover.serialized)

        #expect(read.contextUri == "spotify:station:album:a")
        #expect(read.mainContextUri == "spotify:album:a")
        // The station's rows from the one playing, which a phone does not resolve by itself.
        #expect(read.contextTrackUris == ["spotify:track:s1", "spotify:track:s2"])
        #expect(read.contextTrackUids == ["x1", "x2"])
        #expect(read.currentTrackUri == "spotify:track:s1")
        #expect(read.currentTrackUid == "x1")
        #expect(read.continuesAutoplay)
        #expect(read.autoplayContextUri == "spotify:station:album:a")
        #expect(read.queuedTrackUris.isEmpty)
        #expect(!read.playsQueuedTrack)
        // Paused, the position stands; it is told as of the report.
        #expect(read.positionAsOfTimestamp == 12000)
        #expect(read.timestamp == Self.now)
        #expect(read.isPaused)

        // The album goes with the resolver's metadata, which names it to the device taking over.
        let mainContext = ProtobufReader.fields(in: handover.serialized).last(3)?.fields.last(8)?.fields
        #expect(mainContext?.filter { $0.number == 3 }.map(\.mapEntry.key) == ["context_description"])
    }

    @Test func `a track queued during autoplay is handed over before the station's next row`() throws {
        let queued = state(provider: "queue", uid: "q0", sessionRow: Self.nextAutoplayRow, next: [
            QueueItem(uri: "spotify:track:q2", provider: "queue", uid: "q1"),
            Self.nextAutoplayRow,
        ])
        let handover = try #require(SpircController.handover(of: queued, atMs: Self.now))
        let read = TransferState(parsing: handover.serialized)

        #expect(read.contextUri == "spotify:station:album:a")
        #expect(read.playsQueuedTrack)
        #expect(read.currentTrackUri == "spotify:track:s1")
        #expect(read.contextResumeUid == "x2")
        #expect(read.continuesAutoplay)
        #expect(read.contextTrackUris == ["spotify:track:s2"])
        #expect(read.queuedTrackUris == ["spotify:track:q2"])

        // The queue's head is the playing track, with its uid, as a phone wrote one.
        let head = ProtobufReader.fields(in: handover.serialized).last(4)?.fields.first { $0.number == 1 }?.fields
        #expect(head?.last(2)?.string == "q0")
    }

    /// A phone took a handover's 0 at a track's start as it was, 98 s later (2026-10-02).
    @Test func `a playing track is handed over where it is at the report`() throws {
        let handover = try #require(SpircController.handover(of: state(provider: "autoplay", paused: false), atMs: Self.now))

        #expect(handover.positionAsOfTimestamp == 17000)
        #expect(handover.timestamp == Self.now)
    }

    @Test func `outside autoplay the backend builds the handover itself`() {
        let albumRow = QueueItem(uri: "spotify:track:a3", provider: "context", uid: "c3")
        #expect(SpircController.handover(of: state(provider: "context", sessionRow: albumRow), atMs: Self.now) == nil)
        // A track queued in the album: the album's row comes next.
        #expect(SpircController.handover(of: state(provider: "queue", sessionRow: albumRow, next: [albumRow]), atMs: Self.now) == nil)
        // A station answered without its uri: there is no context to name.
        #expect(SpircController.handover(of: state(provider: "autoplay", station: nil), atMs: Self.now) == nil)
    }
}
