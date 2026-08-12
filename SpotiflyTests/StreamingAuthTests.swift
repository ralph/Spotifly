//
//  StreamingAuthTests.swift
//  SpotiflyTests
//
//  Playing to a remote device when this Mac is not a Connect device.
//

import Foundation
@testable import Spotifly
import Testing

/// What `/me/player/play` is asked to do when playback is routed over the Web API.
///
/// Without streaming credentials this Mac never registers with Spotify Connect, so playback
/// has to go to whatever device is active. `resumePlayback` only resumes what is already
/// loaded — starting an album or a set of tracks needs a body, and the device goes in the
/// query string rather than the body. See
/// `plans/streaming-auth-needs-a-first-party-client-id.md`.
@MainActor
struct StartPlaybackRequestTests {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func `a context start sends context_uri and an offset`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: "spotify:album:a1",
            uris: nil,
            offsetIndex: 3,
            deviceId: nil,
            accessToken: "tok",
        )

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/me/player/play")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let json = try body(request)
        #expect(json["context_uri"] as? String == "spotify:album:a1")
        #expect((json["offset"] as? [String: Any])?["position"] as? Int == 3)
        #expect(!json.keys.contains("uris"))
    }

    @Test func `a track start sends uris and no context`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: nil,
            uris: ["spotify:track:t1", "spotify:track:t2"],
            offsetIndex: nil,
            deviceId: nil,
            accessToken: "tok",
        )

        let json = try body(request)
        #expect(json["uris"] as? [String] == ["spotify:track:t1", "spotify:track:t2"])
        #expect(!json.keys.contains("context_uri"))
        #expect(!json.keys.contains("offset"))
    }

    @Test func `a device id goes in the query, never the body`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: "spotify:album:a1",
            uris: nil,
            offsetIndex: nil,
            deviceId: "dev123",
            accessToken: "tok",
        )

        let query = try #require(request.url?.query)
        #expect(query.contains("device_id=dev123"))
        #expect(try !body(request).keys.contains("device_id"))
    }

    @Test func `an empty uris list is omitted rather than sent empty`() throws {
        // Spotify rejects an empty `uris`; omitting it lets the caller pass a list without
        // having to check it first.
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: "spotify:album:a1",
            uris: [],
            offsetIndex: nil,
            deviceId: nil,
            accessToken: "tok",
        )

        #expect(try !body(request).keys.contains("uris"))
    }
}
