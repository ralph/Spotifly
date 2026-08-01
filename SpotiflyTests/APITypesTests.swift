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

    @Test func `a relinked track keeps the requested identity and playable metadata`() throws {
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

        #expect(decoded.logicalId == "requested")
        #expect(decoded.logicalUri == "spotify:track:requested")
        #expect(track.id == "requested")
        #expect(track.uri == "spotify:track:requested")
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

        #expect(decoded.logicalId == "returned")
        #expect(decoded.logicalUri == "spotify:track:returned")
        #expect(track.id == "returned")
        #expect(track.uri == "spotify:track:returned")
    }
}
