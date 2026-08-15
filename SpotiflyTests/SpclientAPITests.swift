//
//  SpclientAPITests.swift
//  SpotiflyTests
//
//  The REST half: base62 to gid, the preflight, and what metadata/4 returns.
//

import Foundation
@testable import Spotifly
import Testing

/// The id form spclient addresses entities by.
struct SpotifyGIDTests {
    @Test func `a base62 id becomes the hex gid spclient expects`() {
        // Rick Astley, "Never Gonna Give You Up" — the pair the probe exercised against the
        // live service, so this is a known-good conversion rather than a self-consistent one.
        #expect(
            SpotifyGID.gid(fromBase62: "4PTG3Z6ehGkBFwjybzWkR8")
                == "9eee45bc2afa4414a78eadd8bdde5b2e",
        )
    }

    @Test func `the gid is 32 hex characters, zero-padded`() throws {
        let gid = try #require(SpotifyGID.gid(fromBase62: "0000000000000000000001"))

        #expect(gid.count == 32)
        #expect(gid == String(repeating: "0", count: 31) + "1")
    }

    @Test func `something that is not base62 yields nothing`() {
        #expect(SpotifyGID.gid(fromBase62: "not a valid id!") == nil)
        #expect(SpotifyGID.gid(fromBase62: "") == nil)
        // Longer than any Spotify id.
        #expect(SpotifyGID.gid(fromBase62: String(repeating: "z", count: 23)) == nil)
    }

    @Test func `an id too large for sixteen bytes is refused rather than truncated`() {
        // 22 z's overflows 128 bits; silently wrapping would address the wrong track.
        #expect(SpotifyGID.gid(fromBase62: String(repeating: "z", count: 22)) == nil)
    }

    /// The reverse direction, which a track's album and artist references need. Checked
    /// against the same known-good pair rather than only against its own forward conversion.
    @Test func `a gid becomes the base62 id the app keys entities by`() {
        #expect(
            SpotifyGID.base62(fromGID: "9eee45bc2afa4414a78eadd8bdde5b2e")
                == "4PTG3Z6ehGkBFwjybzWkR8",
        )
    }

    @Test func `the base62 id is padded to the full twenty two characters`() throws {
        let id = try #require(SpotifyGID.base62(fromGID: String(repeating: "0", count: 31) + "1"))

        // Trimming this to "1" would produce an id that resolves to nothing.
        #expect(id == "0000000000000000000001")
    }

    @Test func `a gid that is not thirty two hex characters yields nothing`() {
        #expect(SpotifyGID.base62(fromGID: "") == nil)
        #expect(SpotifyGID.base62(fromGID: "9eee45bc") == nil)
        #expect(SpotifyGID.base62(fromGID: String(repeating: "z", count: 32)) == nil)
    }

    @Test func `every id survives the round trip`() throws {
        for id in ["4PTG3Z6ehGkBFwjybzWkR8", "7FcObTmCbQYyC8qzlTL2SE", "459GknUJgpky3io0y482bi"] {
            let gid = try #require(SpotifyGID.gid(fromBase62: id))

            #expect(SpotifyGID.base62(fromGID: gid) == id)
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) -> (Int, Data)

    init(body: Data = Data()) {
        responder = { _ in (200, body) }
    }

    /// For the batch cases, where what comes back has to depend on which track was asked for.
    init(responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        self.responder = responder
    }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        let (status, body) = responder(request)
        return lock.withLock {
            requests.append(request)
            // The preflight is answered separately: it carries no body, and a status meant for
            // the GET would fail the request before it was made.
            let isPreflight = request.httpMethod == "OPTIONS"
            let response = httpResponse(isPreflight ? 200 : status, url: request.url!)
            return (isPreflight ? Data() : body, response)
        }
    }

    var methods: [String] {
        lock.withLock { requests.compactMap(\.httpMethod) }
    }

    var gets: [URLRequest] {
        lock.withLock { requests.filter { $0.httpMethod == "GET" } }
    }
}

struct SpclientAPITests {
    private let trackJSON = Data("""
    {"gid":"9eee45bc2afa4414a78eadd8bdde5b2e","name":"Never Gonna Give You Up",
    "duration":213573,"number":1,"disc_number":1,"has_lyrics":true,
    "artist":[{"gid":"7b6f2a1c9d3e4f5a8b0c1d2e3f4a5b6c","name":"Rick Astley"}],
    "album":{"gid":"1e02b6de7d9c4e0e9a53a1c7f4d9b3a2","name":"Whenever You Need Somebody",
    "cover_group":{"image":[{"file_id":"f1","width":640,"height":640}]}}}
    """.utf8)

    private func api(_ recorder: RequestRecorder) -> SpclientAPI {
        spclientAPI { recorder.handle($0) }
    }

    @Test func `a track is fetched by gid and decoded`() async throws {
        let recorder = RequestRecorder(body: trackJSON)
        let track = try await api(recorder).track(id: "4PTG3Z6ehGkBFwjybzWkR8")

        #expect(track.name == "Never Gonna Give You Up")
        #expect(track.duration == 213_573)
        #expect(track.artistNames == ["Rick Astley"])
        #expect(track.album?.name == "Whenever You Need Somebody")
        #expect(track.album?.coverGroup?.image?.first?.fileId == "f1")
    }

    @Test func `the preflight goes first, then the GET`() async throws {
        // The endpoint is served to the web client's origin, so the sequence is mimicked
        // rather than the request sent bare.
        let recorder = RequestRecorder(body: trackJSON)
        _ = try await api(recorder).track(id: "4PTG3Z6ehGkBFwjybzWkR8")

        #expect(recorder.methods == ["OPTIONS", "GET"])
    }

    @Test func `the request carries both credentials and the market`() async throws {
        let recorder = RequestRecorder(body: trackJSON)
        _ = try await api(recorder).track(id: "4PTG3Z6ehGkBFwjybzWkR8")

        let get = try #require(recorder.requests.last)
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        #expect(get.value(forHTTPHeaderField: "Client-Token") == "ct")
        #expect(get.value(forHTTPHeaderField: "App-Platform") == "OSX_ARM64")
        // Resolves the catalogue against the account rather than the caller's IP.
        #expect(get.url?.query?.contains("market=from_token") == true)
        #expect(get.url?.path.contains("metadata/4/track/9eee45bc2afa4414a78eadd8bdde5b2e") == true)
    }

    @Test func `a bad id fails before any request is made`() async throws {
        let recorder = RequestRecorder(body: trackJSON)

        await #expect(throws: SpclientError.self) {
            _ = try await api(recorder).track(id: "!!!")
        }
        #expect(recorder.requests.isEmpty)
    }

    @Test func `the market is added once, never twice`() throws {
        let once = try SpclientAPI.withMarket(#require(URL(string: "https://spclient.wg.spotify.com/x")))
        let twice = SpclientAPI.withMarket(once)

        #expect(twice.absoluteString == once.absoluteString)
        #expect(once.query == "market=from_token")
    }

    // MARK: - Batches

    /// `metadata/4` addresses one track per request, so a batch is many requests — and the
    /// result has to come back keyed by the id each one was asked for.
    @Test func `a batch asks for every id and keys the result by the requested id`() async throws {
        let ids = ["4PTG3Z6ehGkBFwjybzWkR8", "7FcObTmCbQYyC8qzlTL2SE", "459GknUJgpky3io0y482bi"]
        let recorder = RequestRecorder(body: trackJSON)

        let tracks = try await api(recorder).tracks(ids: ids)

        #expect(Set(tracks.keys) == Set(ids))
        #expect(recorder.gets.count == 3)
    }

    /// The distinction `TrackService` depends on: an id Spotify has no track for is remembered
    /// and never asked for again, so only a genuine 404 may be reported that way.
    @Test func `a track Spotify does not have is absent rather than an error`() async throws {
        let missing = try #require(SpotifyGID.gid(fromBase62: "7FcObTmCbQYyC8qzlTL2SE"))
        let recorder = RequestRecorder(responder: { [trackJSON] request in
            let isMissing = request.url?.path.contains(missing) == true
            return isMissing ? (404, Data()) : (200, trackJSON)
        })

        let tracks = try await api(recorder).tracks(
            ids: ["4PTG3Z6ehGkBFwjybzWkR8", "7FcObTmCbQYyC8qzlTL2SE"],
        )

        #expect(Array(tracks.keys) == ["4PTG3Z6ehGkBFwjybzWkR8"])
    }

    /// The other half of that distinction. A 500 might not recur, so it must not be recorded
    /// as a track that does not exist — it fails the whole batch and the caller retries.
    @Test func `a failed request throws rather than reporting the track as absent`() async throws {
        let recorder = RequestRecorder(responder: { _ in (500, Data()) })

        await #expect(throws: SpclientError.self) {
            _ = try await self.api(recorder).tracks(ids: ["4PTG3Z6ehGkBFwjybzWkR8"])
        }
    }

    @Test func `an empty batch makes no request at all`() async throws {
        let recorder = RequestRecorder(body: trackJSON)

        let tracks = try await api(recorder).tracks(ids: [])

        #expect(tracks.isEmpty)
        #expect(recorder.requests.isEmpty)
    }

    // MARK: - Entities

    @Test @MainActor func `a track entity carries the requested id and its linked ids`() async throws {
        let recorder = RequestRecorder(body: trackJSON)

        let entities = try await api(recorder).trackEntities(ids: ["4PTG3Z6ehGkBFwjybzWkR8"])
        let track = try #require(entities["4PTG3Z6ehGkBFwjybzWkR8"])

        #expect(track.id == "4PTG3Z6ehGkBFwjybzWkR8")
        #expect(track.uri == "spotify:track:4PTG3Z6ehGkBFwjybzWkR8")
        #expect(track.name == "Never Gonna Give You Up")
        #expect(track.durationMs == 213_573)
        #expect(track.artistName == "Rick Astley")
        #expect(track.albumName == "Whenever You Need Somebody")
        // Referenced by gid on the wire, keyed by base62 in the store.
        #expect(track.albumId == "0UD0DrXpjD9uNimehd9s5k")
        #expect(track.artistId == "3KURedvMNaODRmz9YEpGs4")
    }

    /// spclient names cover art by file id, so the URL has to be assembled rather than read.
    @Test @MainActor func `cover art file ids become image URLs`() async throws {
        let recorder = RequestRecorder(body: trackJSON)

        let entities = try await api(recorder).trackEntities(ids: ["4PTG3Z6ehGkBFwjybzWkR8"])
        let track = try #require(entities["4PTG3Z6ehGkBFwjybzWkR8"])

        #expect(track.images.url(for: 320, scale: 2)?.absoluteString == "https://i.scdn.co/image/f1")
    }

    /// A gid that is not 32 hex characters leaves the link empty rather than pointing the
    /// store at whatever a best-effort conversion produced.
    @Test @MainActor func `an unreadable album gid leaves the track unlinked`() async throws {
        let json = Data("""
        {"gid":"9eee45bc2afa4414a78eadd8bdde5b2e","name":"Track","duration":1000,
        "album":{"gid":"nonsense","name":"Album"}}
        """.utf8)
        let recorder = RequestRecorder(body: json)

        let entities = try await api(recorder).trackEntities(ids: ["4PTG3Z6ehGkBFwjybzWkR8"])
        let track = try #require(entities["4PTG3Z6ehGkBFwjybzWkR8"])

        #expect(track.albumId == nil)
        #expect(track.albumName == "Album")
    }

    // MARK: - Client token recovery

    /// The same rule as `PartnerAPI`: a client token can die before its stated expiry, and it
    /// is cached — so without this the whole REST half stays 401 until the app is relaunched.
    @Test func `a 401 drops the cached client token and retries once`() async throws {
        let rejected = Recorder<String>()
        let attempts = Tally()
        let recorder = RequestRecorder(responder: { [trackJSON] request in
            // The responder sees the preflight too; only the GET is the request under test.
            guard request.httpMethod != "OPTIONS" else { return (200, Data()) }
            attempts.increment()
            return attempts.count == 1 ? (401, Data()) : (200, trackJSON)
        })

        let api = spclientAPI(invalidateClientToken: { rejected.record($0) }) { recorder.handle($0) }

        let track = try await api.track(id: "4PTG3Z6ehGkBFwjybzWkR8")

        #expect(track.name == "Never Gonna Give You Up")
        // The token the refused request carried, not whatever is cached by the time it lands.
        #expect(rejected.values == ["ct"])
        #expect(recorder.methods == ["OPTIONS", "GET", "OPTIONS", "GET"])
    }

    @Test func `a second 401 is reported rather than retried again`() async throws {
        let rejected = Recorder<String>()
        let recorder = RequestRecorder(responder: { _ in (401, Data()) })

        let api = spclientAPI(invalidateClientToken: { rejected.record($0) }) { recorder.handle($0) }

        await #expect(throws: SpclientError.self) {
            _ = try await api.track(id: "4PTG3Z6ehGkBFwjybzWkR8")
        }
        #expect(rejected.values == ["ct"])
        #expect(recorder.gets.count == 2)
    }
}
