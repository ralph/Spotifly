//
//  PlaylistChangesTests.swift
//  SpotiflyTests
//
//  The bodies `playlist/v2` takes, pinned to the ones the web client sends.
//

import Foundation
@testable import Spotifly
import Testing

/// Every fixture below was read off the network tab while Spotify's own web client created,
/// renamed, followed and deleted a playlist, on 2026-08-14. They are the request bodies
/// verbatim.
///
/// **Pinning the encoders to them is the whole point.** This service has no schema to validate
/// against and answers a wrong-but-plausible body with a 200 and a revision, so an envelope
/// that drifted from the client's would look like it had worked. The shapes are also genuinely
/// dissimilar — creating sends a bare `OpList`, everything else wraps ops in `ListChanges`, and
/// two of the three ops go to a different endpoint than the third — which is exactly the kind
/// of distinction that gets tidied away by mistake later.
struct PlaylistChangeBodyTests {
    /// `POST /playlist/v2/playlist`
    static let webClientCreate = """
    {"ops":[{"kind":"UPDATE_LIST_ATTRIBUTES","updateListAttributes":{"newAttributes":\
    {"values":{"name":"Meine Playlist Nr. 37"}}}}]}
    """

    /// The response to that create.
    static let webClientCreateReply = """
    {"uri":"spotify:playlist:1k9WHPIpmwjS9aOj3EGaVM","revision":"AAAAAVF7XtL/a6Hw/8n7ajY+TY+Q3ut1"}
    """

    /// `POST /playlist/v2/playlist/2Cngv8qX0kwH5vwkOY6wdJ/changes`
    static let webClientRename = """
    {"deltas":[{"ops":[{"kind":"UPDATE_LIST_ATTRIBUTES","updateListAttributes":{"newAttributes":\
    {"values":{"name":"relink-test abc","description":"description abc"}}}}],\
    "info":{"source":{"client":"WEBPLAYER"}}}]}
    """

    /// `POST /playlist/v2/user/{username}/rootlist/changes` — following a playlist.
    static let webClientFollow = """
    {"deltas":[{"ops":[{"kind":"ADD","add":{"items":[\
    {"uri":"spotify:playlist:25dIxWREnlY6a37FMj1sST","attributes":{"timestamp":"1786645835061"}}],\
    "addFirst":true}}],"info":{"source":{"client":"WEBPLAYER"}}}]}
    """

    /// The same endpoint — deleting a playlist the user owns.
    static let webClientDelete = """
    {"deltas":[{"ops":[{"kind":"REM","rem":{"items":[\
    {"uri":"spotify:playlist:1k9WHPIpmwjS9aOj3EGaVM"}],"itemsAsKey":true}}],\
    "info":{"source":{"client":"WEBPLAYER"}}}]}
    """

    /// The instant in the follow fixture: 1786645835061 milliseconds after the epoch.
    static let followedAt = Date(timeIntervalSince1970: 1_786_645_835.061)

    private func fields(_ data: Data) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
    }

    private func expectMatch(_ encoded: Data, _ fixture: String) throws {
        let ours = try #require(fields(encoded))
        let theirs = try #require(fields(Data(fixture.utf8)))
        #expect(ours == theirs)
    }

    @Test func `creating sends what the web client sends`() throws {
        let encoded = try JSONEncoder().encode(PlaylistCreation(name: "Meine Playlist Nr. 37"))

        try expectMatch(encoded, Self.webClientCreate)
    }

    @Test func `renaming sends what the web client sends`() throws {
        let encoded = try JSONEncoder().encode(
            PlaylistListChanges(
                .attributes(name: "relink-test abc", description: "description abc"),
            ),
        )

        try expectMatch(encoded, Self.webClientRename)
    }

    @Test func `following sends what the web client sends`() throws {
        let encoded = try JSONEncoder().encode(
            PlaylistListChanges(
                .add(uris: ["spotify:playlist:25dIxWREnlY6a37FMj1sST"], addedAt: Self.followedAt),
            ),
        )

        try expectMatch(encoded, Self.webClientFollow)
    }

    @Test func `deleting sends what the web client sends`() throws {
        let encoded = try JSONEncoder().encode(
            PlaylistListChanges(.remove(uris: ["spotify:playlist:1k9WHPIpmwjS9aOj3EGaVM"])),
        )

        try expectMatch(encoded, Self.webClientDelete)
    }

    /// The partial-state rule, which is the one that would cost a user their words: renaming a
    /// playlist must not carry a description at all, or it would overwrite whatever is there
    /// with whatever the caller happened to pass — in the app's case, nothing.
    @Test func `a rename leaves the description out of the payload entirely`() throws {
        let encoded = try JSONEncoder().encode(PlaylistListChanges(.attributes(
            name: "just the name",
            description: nil,
        )))

        #expect(!String(decoding: encoded, as: UTF8.self).contains("description"))
    }

    /// The mirror of it: editing the description must not blank the name.
    @Test func `a described playlist keeps its name out of the payload entirely`() throws {
        let encoded = try JSONEncoder().encode(PlaylistListChanges(.attributes(
            name: nil,
            description: "just the text",
        )))

        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"name\""))
    }

    /// A removal names the playlist rather than a position. Without `itemsAsKey` the same
    /// message means "drop `length` items from `fromIndex`", so a library that reordered
    /// underneath us would delete something else.
    @Test func `a removal keys on the uri rather than a position`() throws {
        let encoded = try JSONEncoder().encode(
            PlaylistListChanges(.remove(uris: ["spotify:playlist:1k9WHPIpmwjS9aOj3EGaVM"])),
        )
        let body = String(decoding: encoded, as: UTF8.self)

        #expect(body.contains("\"itemsAsKey\":true"))
        #expect(!body.contains("fromIndex"))
    }

    /// The timestamp is an `int64`, which proto3's JSON mapping renders as a *string* so it
    /// survives languages whose numbers stop short of 64 bits. Sending it as a number would be
    /// the natural Swift thing to do and would not match the client.
    @Test func `the added-at time is quoted, not a number`() throws {
        let encoded = try JSONEncoder().encode(
            PlaylistListChanges(.add(uris: ["spotify:playlist:x"], addedAt: Self.followedAt)),
        )

        #expect(String(decoding: encoded, as: UTF8.self).contains("\"timestamp\":\"1786645835061\""))
    }

    @Test func `the create reply names the playlist Spotify made`() throws {
        let reply = try JSONDecoder().decode(
            PlaylistCreationReply.self,
            from: Data(Self.webClientCreateReply.utf8),
        )

        #expect(reply.uri == "spotify:playlist:1k9WHPIpmwjS9aOj3EGaVM")
        #expect(SpotifyURI.id(from: reply.uri) == "1k9WHPIpmwjS9aOj3EGaVM")
    }
}
