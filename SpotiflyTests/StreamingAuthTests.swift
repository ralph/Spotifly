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

/// Where a play request goes when this Mac may or may not be a Connect device.
///
/// Local wins whenever it exists. Otherwise an active remote device serves the request over
/// the Web API — pressing play while a phone is playing must not nag about local streaming.
/// Only when there is nothing anywhere is there anything to ask the user about.
@MainActor
struct PlaybackTargetTests {
    @Test func `a local player takes precedence`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: true, activeDeviceId: "dev1")
                == .local,
        )
    }

    @Test func `a local player is used even with no device recorded`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: true, activeDeviceId: nil)
                == .local,
        )
    }

    @Test func `no local player routes to the active remote device`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: false, activeDeviceId: "dev1")
                == .remote(deviceId: "dev1"),
        )
    }

    @Test func `nothing anywhere asks for authorization`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: false, activeDeviceId: nil)
                == .needsAuthorization,
        )
    }
}

/// Splitting a play request into what `/me/player/play` accepts.
///
/// Spotify takes albums, playlists and artists as `context_uri`, but individual tracks only
/// in `uris` — sending a track as a context fails. `playTrack` and the queue both hand
/// `play(uriOrUrl:)` a bare `spotify:track:` URI, so the remote path has to tell them apart.
@MainActor
struct RemoteStartPayloadTests {
    @Test func `a track becomes a one-element uris list`() {
        let payload = PlaybackViewModel.remoteStartPayload(for: "spotify:track:t1")
        #expect(payload.contextUri == nil)
        #expect(payload.uris == ["spotify:track:t1"])
    }

    @Test func `an album stays a context`() {
        let payload = PlaybackViewModel.remoteStartPayload(for: "spotify:album:a1")
        #expect(payload.contextUri == "spotify:album:a1")
        #expect(payload.uris == nil)
    }

    @Test func `a playlist stays a context`() {
        let payload = PlaybackViewModel.remoteStartPayload(for: "spotify:playlist:p1")
        #expect(payload.contextUri == "spotify:playlist:p1")
        #expect(payload.uris == nil)
    }

    @Test func `an artist stays a context`() {
        // Artists are a valid Web API context, unlike tracks.
        let payload = PlaybackViewModel.remoteStartPayload(for: "spotify:artist:ar1")
        #expect(payload.contextUri == "spotify:artist:ar1")
        #expect(payload.uris == nil)
    }

    @Test func `a track URL is recognised as a track`() {
        let payload = PlaybackViewModel.remoteStartPayload(
            for: "https://open.spotify.com/track/t1?si=abc",
        )
        #expect(payload.contextUri == nil)
        #expect(payload.uris == ["spotify:track:t1"])
    }
}

/// Whether the two grants authorized the same Spotify account.
///
/// The streaming grant runs in the browser, with whatever account that browser is signed
/// into. Accepting a mismatch would leave the app browsing and editing one account while
/// playing and queueing on another, with nothing on screen saying so.
@MainActor
struct AccountMismatchTests {
    @Test func `matching accounts are no mismatch`() {
        #expect(AuthViewModel.accountMismatch(expected: "userA", granted: "userA") == nil)
    }

    @Test func `different accounts are reported`() {
        let mismatch = AuthViewModel.accountMismatch(expected: "userA", granted: "userB")
        #expect(mismatch != nil)
        #expect(mismatch?.contains("userB") == true)
    }

    @Test func `an unknown signed-in account counts as agreement`() {
        // Refusing a grant because an identity was briefly unavailable would be worse than
        // the case being guarded against, which needs a deliberate second sign-in.
        #expect(AuthViewModel.accountMismatch(expected: nil, granted: "userB") == nil)
    }

    @Test func `an unknown grant account counts as agreement`() {
        #expect(AuthViewModel.accountMismatch(expected: "userA", granted: nil) == nil)
    }
}

/// How the grant's exit codes reach the UI.
struct StreamingAuthResultTests {
    @Test func `zero is success`() {
        #expect(StreamingAuthResult(code: 0) == .authorized)
    }

    @Test func `minus one is a failure worth reporting`() {
        #expect(StreamingAuthResult(code: -1) == .failed)
    }

    @Test func `minus two is a supersession, which is not an error`() {
        // A logout landed mid-grant and the credentials it wrote were removed again.
        // Nothing went wrong, so the UI must report neither success nor failure.
        #expect(StreamingAuthResult(code: -2) == .superseded)
    }

    @Test func `an unknown code is treated as a failure`() {
        #expect(StreamingAuthResult(code: 99) == .failed)
    }
}
