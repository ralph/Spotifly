//
//  StreamingAuthTests.swift
//  SpotiflyTests
//
//  Playing to a remote device when this Mac is not a Connect device.
//

import Foundation
@testable import Spotifly
import Testing

/// Turning a play request into the uri connect-state takes.
///
/// The Web API needed this split into `context_uri` *or* `uris`, because sending a track as a
/// context failed. connect-state takes one uri and decides for itself — so what is left to get
/// right is the normalization: `play(uriOrUrl:)` accepts a share link as readily as a uri, and
/// only the uri form can be played.
@MainActor
struct RemoteStartUriTests {
    @Test func `a track uri passes through`() {
        #expect(PlaybackViewModel.remoteStartUri(for: "spotify:track:t1") == "spotify:track:t1")
    }

    @Test func `contexts pass through unchanged`() {
        for uri in ["spotify:album:a1", "spotify:playlist:p1", "spotify:artist:ar1"] {
            #expect(PlaybackViewModel.remoteStartUri(for: uri) == uri)
        }
    }

    @Test func `a track URL becomes a track uri`() {
        #expect(
            PlaybackViewModel.remoteStartUri(for: "https://open.spotify.com/track/t1?si=abc")
                == "spotify:track:t1",
        )
    }
}

/// How a play request is carried, which is where the Web API was more forgiving.
///
/// `/me/player/play` took a bare `uris` array; connect-state plays **contexts**, so a single
/// track has to be sent as a context with a `skip_to` naming it, and a bare list of tracks as
/// an inline context with its own `pages`. Sending a track uri as a plain context plays the
/// first track of whatever Spotify resolves it to instead.
struct ConnectPlayCommandTests {
    private func encoded(_ command: ConnectCommand) throws -> String {
        let data = try JSONEncoder().encode(ConnectCommandEnvelope(command))
        return try #require(String(data: data, encoding: .utf8))
    }

    /// The **command object**, unwrapped from the envelope it is sent in. Decoded rather than
    /// matched as a substring: `JSONEncoder` escapes forward slashes, so the `context://` url
    /// is on the wire as `context:\/\/` and a literal search misses it.
    private func fields(_ command: ConnectCommand) throws -> [String: Any] {
        let data = try JSONEncoder().encode(ConnectCommandEnvelope(command))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(body["command"] as? [String: Any])
    }

    @Test func `a track is a context plus a skip_to naming it`() throws {
        let command = try fields(.play(uri: "spotify:track:t1"))

        #expect(command["endpoint"] as? String == "play")

        let context = try #require(command["context"] as? [String: Any])
        #expect(context["uri"] as? String == "spotify:track:t1")
        #expect(context["url"] as? String == "context://spotify:track:t1")

        let options = try #require(command["options"] as? [String: Any])
        let skipTo = try #require(options["skip_to"] as? [String: Any])
        #expect(skipTo["track_uri"] as? String == "spotify:track:t1")
    }

    @Test func `a context with an index skips to that index instead`() throws {
        let json = try encoded(.play(uri: "spotify:album:a1", trackIndex: 4))

        #expect(json.contains("\"track_index\":4"))
        #expect(!json.contains("track_uri"))
    }

    @Test func `a context with no index carries no skip_to at all`() throws {
        let json = try encoded(.play(uri: "spotify:album:a1"))

        #expect(!json.contains("skip_to"))
    }

    /// A negative index means "no offset" at the call site, and must not become `skip_to: -1`.
    @Test func `a negative index is no index`() throws {
        let json = try encoded(.play(uri: "spotify:album:a1", trackIndex: -1))

        #expect(!json.contains("skip_to"))
    }

    @Test func `a bare track list becomes an inline context`() throws {
        let json = try encoded(.play(trackUris: ["spotify:track:t1", "spotify:track:t2"]))

        #expect(json.contains("\"pages\""))
        #expect(json.contains("spotify:track:t1"))
        #expect(json.contains("spotify:track:t2"))
    }
}

/// The transport commands, whose bodies differ only in one field.
struct ConnectCommandTests {
    private func encoded(_ command: ConnectCommand) throws -> String {
        let data = try JSONEncoder().encode(ConnectCommandEnvelope(command))
        return try #require(String(data: data, encoding: .utf8))
    }

    /// **The command goes inside a `command` object.** Sending its fields at the top level is
    /// answered with `BAD_COMMAND: Payload does not contain a command object` — which the
    /// first version of this did, because every test here asserted on the command's own shape
    /// and none on the body that leaves the app.
    @Test func `a command is wrapped in a command object`() throws {
        let data = try JSONEncoder().encode(ConnectCommandEnvelope(.pause))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(body["endpoint"] == nil)

        let command = try #require(body["command"] as? [String: Any])
        #expect(command["endpoint"] as? String == "pause")
    }

    @Test func `the simple commands name only their endpoint`() throws {
        let cases: [(ConnectCommand, String)] = [
            (.pause, "pause"),
            (.resume, "resume"),
            (.next, "skip_next"),
            (.previous, "skip_prev"),
        ]

        for (command, endpoint) in cases {
            let json = try encoded(command)
            #expect(json.contains("\"endpoint\":\"\(endpoint)\""))
            #expect(json.contains("command_id"))
            #expect(!json.contains("\"value\""))
        }
    }

    /// `seek_to` and `set_shuffling_context` both carry their argument under `value`, one as a
    /// number and one as a boolean — which is why the two Swift properties encode to one key.
    @Test func `seek and shuffle share the value key with different types`() throws {
        #expect(try encoded(.seek(toMs: 42000)).contains("\"value\":42000"))
        #expect(try encoded(.shuffle(true)).contains("\"value\":true"))
        #expect(try encoded(.shuffle(false)).contains("\"value\":false"))
    }

    @Test func `a negative seek is clamped rather than sent`() throws {
        #expect(try encoded(.seek(toMs: -5)).contains("\"value\":0"))
    }

    /// The wire wants 0…65535 where the app and the Web API both use a percentage.
    @Test func `volume is converted from a percentage`() throws {
        func volume(_ percent: Int) throws -> Int {
            let data = try JSONEncoder().encode(ConnectVolume(percent: percent))
            struct Body: Decodable { let volume: Int }
            return try JSONDecoder().decode(Body.self, from: data).volume
        }

        #expect(try volume(0) == 0)
        #expect(try volume(100) == 65535)
        #expect(try volume(50) == 32768)
        // Out of range in either direction is clamped, not wrapped.
        #expect(try volume(-10) == 0)
        #expect(try volume(150) == 65535)
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
