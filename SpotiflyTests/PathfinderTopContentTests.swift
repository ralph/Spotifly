//
//  PathfinderTopContentTests.swift
//  SpotiflyTests
//
//  The start page's top tracks and artists, as `userTopContent` sends them.
//

import Foundation
@testable import Spotifly
import Testing

/// A real `userTopContent` response, `MID_TERM`, one of each, replayed in the web player's page on
/// open.spotify.com on 2026-10-21 (the tracks and the artists came from two replays, one with
/// `includeTopArtists` false; they are joined here). Nothing is trimmed.
private let capturedResponse = #"""
{"data":{"me":{"profile":{"topArtists":{"__typename":"ArtistPageV2","items":[{"data":{"__typename":"Artist","profile":{"name":"The Gaslight Anthem"},"uri":"spotify:artist:7If8DXZN7mlGdQkLE2FaMo","visuals":{"avatarImage":{"sources":[{"height":640,"url":"https://i.scdn.co/image/ab6761610000e5eb6e8b0c6a8eb524a5db7c340f","width":640},{"height":160,"url":"https://i.scdn.co/image/ab6761610000f1786e8b0c6a8eb524a5db7c340f","width":160},{"height":320,"url":"https://i.scdn.co/image/ab676161000051746e8b0c6a8eb524a5db7c340f","width":320}]}}}}],"totalCount":36},"topTracks":{"__typename":"TrackPageV2","items":[{"data":{"__typename":"Track","albumOfTrack":{"coverArt":{"sources":[{"height":300,"url":"https://i.scdn.co/image/ab67616d00001e02c1c26524481013b7f3fd4a2a","width":300},{"height":64,"url":"https://i.scdn.co/image/ab67616d00004851c1c26524481013b7f3fd4a2a","width":64},{"height":640,"url":"https://i.scdn.co/image/ab67616d0000b273c1c26524481013b7f3fd4a2a","width":640}]},"name":"Not Bad for New Jersey","uri":"spotify:album:1LVj9ljlwsn2DOsXkRDOeI"},"artists":{"items":[{"profile":{"name":"Brian Fallon"},"uri":"spotify:artist:3JlzEFwarS8ZcCGNFy11y4"}]},"associationsV3":{"audioAssociations":{"totalCount":0},"videoAssociations":{"totalCount":0}},"contentRating":{"label":"NONE"},"duration":{"totalMilliseconds":215205},"mediaType":"AUDIO","name":"Not Bad for New Jersey","saved":false,"uri":"spotify:track:2J1gYYXbLb3JJWjbOS6DJO","visualIdentity":{"sixteenByNineCoverImage":null}}}],"totalCount":532}}}}}
"""#

@MainActor
struct PathfinderTopContentTests {
    @Test func `a top track takes its id from its uri, which is all it sends`() throws {
        let response = try JSONDecoder().decode(PathfinderTopContentResponse.self, from: Data(capturedResponse.utf8))

        let track = try #require(response.tracks.first)
        #expect(track.id == "2J1gYYXbLb3JJWjbOS6DJO")
        #expect(track.name == "Not Bad for New Jersey")
        #expect(track.artistName == "Brian Fallon")
        #expect(track.albumId == "1LVj9ljlwsn2DOsXkRDOeI")
        #expect(track.durationMs == 215_205)
    }

    @Test func `a top artist decodes as an artist`() throws {
        let response = try JSONDecoder().decode(PathfinderTopContentResponse.self, from: Data(capturedResponse.utf8))

        let artist = try #require(response.artists.first)
        #expect(artist.id == "7If8DXZN7mlGdQkLE2FaMo")
        #expect(artist.name == "The Gaslight Anthem")
    }

    /// `MEDIUM_TERM`, the Web API's name for the middle range, is refused with 400; the three
    /// sent are the ones that answered 200 on 2026-10-21.
    @Test func `the ranges are sent as AffinityTimeRange names them`() throws {
        let data = try JSONEncoder().encode(PathfinderTopContentVariables(range: .mid, limit: 10))
        let variables = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tracks = try #require(variables["topTracksInput"] as? [String: Any])

        #expect(tracks["timeRange"] as? String == "MID_TERM")
        #expect(tracks["sortBy"] as? String == "AFFINITY")
        #expect(tracks["limit"] as? Int == 10)
        #expect(TopContentRange.allCases.map(\.rawValue) == ["SHORT_TERM", "MID_TERM", "LONG_TERM"])
    }
}
