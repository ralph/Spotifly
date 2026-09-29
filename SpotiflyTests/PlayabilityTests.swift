//
//  PlayabilityTests.swift
//  SpotiflyTests
//
//  Whether Spotify will play a track, as each answer that carries it says.
//

import Foundation
@testable import Spotifly
import Testing

/// The shapes measured on 2026-09-29, with "Girlfriend (feat. Dâm-Funk)", which Spotify
/// withholds in Germany.
@MainActor
struct PlayabilityTests {
    private static func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func `a playlist's withheld track is unplayable, with Spotify's reason`() throws {
        let track = try Self.decode(PathfinderPlaylistTrack.self, """
        {"uri":"spotify:track:6PpbRUIbMyUbJkWHS3eQ8j","name":"Girlfriend (feat. Dâm-Funk)",
         "playability":{"playable":false,"reason":"COUNTRY_RESTRICTED"}}
        """)

        let entity = try #require(Track(pathfinderPlaylistTrack: track))

        #expect(entity.playability == .unplayable(reason: "COUNTRY_RESTRICTED"))
        #expect(!entity.isPlayable)
    }

    /// The album's answer said `playable: false` and gave no reason.
    @Test func `an album's withheld track is unplayable without a reason`() throws {
        let track = try Self.decode(PathfinderAlbumTrack.self, """
        {"uri":"spotify:track:6PpbRUIbMyUbJkWHS3eQ8j","name":"Girlfriend (feat. Dâm-Funk)",
         "playability":{"playable":false}}
        """)

        let entity = try #require(Track(pathfinderAlbumTrack: track, albumId: "album", albumName: nil, images: .empty))

        #expect(entity.playability == .unplayable(reason: nil))
    }

    @Test func `a playable search result, and one whose answer does not say, both play`() throws {
        let said = try Self.decode(PathfinderTrack.self, """
        {"id":"a","uri":"spotify:track:a","name":"A","playability":{"playable":true,"reason":"PLAYABLE"}}
        """)
        let unsaid = try Self.decode(PathfinderTrack.self, """
        {"id":"b","uri":"spotify:track:b","name":"B"}
        """)

        #expect(try #require(Track(pathfinder: said)).isPlayable)
        #expect(try #require(Track(pathfinder: unsaid)).isPlayable)
    }

    @Test func `the message names the country only where that is Spotify's reason`() {
        func track(_ playability: Playability) -> Track {
            var track = Track(
                id: "g", name: "Girlfriend", uri: "spotify:track:g", durationMs: 0, trackNumber: nil,
                externalUrl: nil, albumId: nil, artistId: nil, artistName: "", albumName: nil, images: .empty,
            )
            track.playability = playability
            return track
        }

        #expect(track(.playable).unplayableMessage == nil)
        #expect(track(.unplayable(reason: "COUNTRY_RESTRICTED")).unplayableMessage
            == String(localized: "error.track_unavailable_in_country \("Girlfriend")"))
        #expect(track(.unplayable(reason: nil)).unplayableMessage
            == String(localized: "error.track_unavailable \("Girlfriend")"))
    }
}
