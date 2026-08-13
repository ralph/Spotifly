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
    /// `/v1/tracks?ids=` answers positionally and keeps the slot of an ID it has no
    /// track for. `fetchTracks` zips the response back onto the requested IDs, so a
    /// dropped null would shift every later track onto the wrong ID.
    @Test func `a tracks response keeps the slot of an unavailable track`() throws {
        let json = Data("""
        {"tracks": [
            {"id": "first", "name": "First", "uri": "spotify:track:first", "duration_ms": 1000},
            null,
            {"id": "third", "name": "Third", "uri": "spotify:track:third", "duration_ms": 3000}
        ]}
        """.utf8)

        let decoded = try JSONDecoder().decode(TracksCodable.self, from: json)

        #expect(decoded.tracks.count == 3)
        #expect(decoded.tracks[0]?.id == "first")
        #expect(decoded.tracks[1] == nil)
        #expect(decoded.tracks[2]?.id == "third")

        // The zip fetchTracks performs, spelled out: the null must not consume an ID.
        let requestedIds = ["first", "missing", "third"]
        var mapped: [String: String] = [:]
        for (trackId, track) in zip(requestedIds, decoded.tracks) {
            if let track {
                mapped[trackId] = track.name
            }
        }

        #expect(mapped == ["first": "First", "third": "Third"])
    }

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
