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
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private let body: Data

    init(body: Data = Data()) {
        self.body = body
    }

    func handle(_ request: URLRequest) -> (Data, URLResponse) {
        lock.withLock {
            requests.append(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil,
            )!
            return (request.httpMethod == "OPTIONS" ? Data() : body, response)
        }
    }

    var methods: [String] {
        lock.withLock { requests.compactMap(\.httpMethod) }
    }
}

struct SpclientAPITests {
    private let trackJSON = Data("""
    {"gid":"9eee45bc2afa4414a78eadd8bdde5b2e","name":"Never Gonna Give You Up",
    "duration":213573,"number":1,"disc_number":1,"has_lyrics":true,
    "artist":[{"gid":"a1","name":"Rick Astley"}],
    "album":{"gid":"al1","name":"Whenever You Need Somebody",
    "cover_group":{"image":[{"file_id":"f1","width":640,"height":640}]}}}
    """.utf8)

    private func api(_ recorder: RequestRecorder) -> SpclientAPI {
        SpclientAPI(accessToken: { "at" }, clientToken: { "ct" }, transport: { recorder.handle($0) })
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
}
