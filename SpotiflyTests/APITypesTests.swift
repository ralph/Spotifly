//
//  APITypesTests.swift
//  SpotiflyTests
//
//  Decoding contracts that the API layer relies on.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct APITypesTests {
    /// The market id is the identity, so a `linked_from` in the response changes nothing: the
    /// track is keyed by the recording that plays here, which is the same id pathfinder hands
    /// search. The opposite rule held until the partner APIs arrived, and reversing it is what
    /// stopped a searched track and a saved one from being two different tracks.
    @Test func `a relinked track keeps the market identity, not the original`() throws {
        let json = Data("""
        {
            "id": "playable",
            "name": "Playable metadata",
            "uri": "spotify:track:playable",
            "duration_ms": 4321,
            "linked_from": {
                "id": "requested",
                "uri": "spotify:track:requested"
            }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TrackCodable.self, from: json)
        let track = decoded.toAPITrack()

        #expect(track.id == "playable")
        #expect(track.uri == "spotify:track:playable")
        #expect(track.name == "Playable metadata")
        #expect(track.durationMs == 4321)
    }

    /// `/albums/{id}/tracks` decodes through its own type rather than `TrackCodable`, so it
    /// has to reach the same answer by its own route.
    @Test func `a relinked album track keeps the market identity`() throws {
        let json = Data("""
        {"items": [{
            "id": "playable",
            "name": "Playable metadata",
            "uri": "spotify:track:playable",
            "duration_ms": 4321,
            "track_number": 2,
            "linked_from": {"id": "requested", "uri": "spotify:track:requested"}
        }]}
        """.utf8)

        let decoded = try JSONDecoder().decode(AlbumTracksCodable.self, from: json)
        let item = try #require(decoded.items.first)
        let track = item.toAPITrack(albumId: "album", albumName: "Album", images: .empty)

        #expect(track.id == "playable")
        #expect(track.uri == "spotify:track:playable")
        #expect(track.name == "Playable metadata")
        #expect(track.durationMs == 4321)
    }

    @Test func `a track without relinking keeps its returned identity`() throws {
        let json = Data("""
        {
            "id": "returned",
            "name": "Returned metadata",
            "uri": "spotify:track:returned",
            "duration_ms": 1234
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TrackCodable.self, from: json)
        let track = decoded.toAPITrack()

        #expect(track.id == "returned")
        #expect(track.uri == "spotify:track:returned")
    }
}
