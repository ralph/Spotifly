//
//  PathfinderAlbumTests.swift
//  SpotiflyTests
//
//  What `getAlbum` returns, and the entities it becomes.
//

import Foundation
@testable import Spotifly
import Testing

/// The fixture is trimmed from a real `getAlbum` response for Daft Punk's Discovery, taken
/// with the probe on 2026-08-13 — field names and nesting are as the service sent them, not as
/// they seemed reasonable. The search decoder was written the other way round once, and its
/// unit tests passed while three of the four result categories came back empty.
private let discoveryJSON = Data("""
{"data":{"albumUnion":{
  "__typename":"Album",
  "uri":"spotify:album:2noRn2Aes5aoNVsU6iWThc",
  "name":"Discovery",
  "type":"ALBUM",
  "date":{"isoString":"2001-03-12T00:00:00Z","precision":"DAY"},
  "coverArt":{"sources":[
    {"url":"https://i.scdn.co/image/large","width":640,"height":640},
    {"url":"https://i.scdn.co/image/small","width":64,"height":64}
  ]},
  "artists":{"items":[
    {"id":"4tZwfgrHOc3mvqYlEYSvVi","uri":"spotify:artist:4tZwfgrHOc3mvqYlEYSvVi",
     "profile":{"name":"Daft Punk"}}
  ]},
  "tracksV2":{"totalCount":14,"items":[
    {"uid":"a1","track":{
      "uri":"spotify:track:0DiWol3AO6WpXZgp0goxAV","name":"One More Time",
      "trackNumber":1,"discNumber":1,
      "duration":{"totalMilliseconds":320357},
      "playability":{"playable":true},
      "relinkingInformation":{"__typename":"TrackRelinkingInformation"},
      "artists":{"items":[{"uri":"spotify:artist:4tZwfgrHOc3mvqYlEYSvVi",
                           "profile":{"name":"Daft Punk"}}]}}},
    {"uid":"a2","track":{
      "uri":"spotify:track:3H3cOQ6LBLSvmcaV7QkZEu","name":"Aerodynamic",
      "trackNumber":2,"discNumber":1,
      "duration":{"totalMilliseconds":212546},
      "playability":{"playable":true},
      "artists":{"items":[{"uri":"spotify:artist:4tZwfgrHOc3mvqYlEYSvVi",
                           "profile":{"name":"Daft Punk"}}]}}}
  ]}
}}}
""".utf8)

private func decodeDiscovery() throws -> PathfinderAlbumUnion {
    let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: discoveryJSON)
    return try #require(response.data?.albumUnion)
}

struct PathfinderAlbumTests {
    @Test func `the album envelope decodes down to its tracks`() throws {
        let album = try decodeDiscovery()

        #expect(album.id == "2noRn2Aes5aoNVsU6iWThc")
        #expect(album.name == "Discovery")
        #expect(album.type == "ALBUM")
        #expect(album.tracksV2?.totalCount == 14)
        #expect(album.tracks.count == 2)
        #expect(album.firstArtist?.profile?.name == "Daft Punk")
    }

    /// `tracksV2`, not `tracks`. The other album operation, `getAlbumNameAndTracks`, uses the
    /// same key for items holding nothing but a `uri`, so reading the wrong one yields a track
    /// list with no names or durations rather than an error.
    @Test func `the track list is read from tracksV2`() throws {
        let album = try decodeDiscovery()
        let first = try #require(album.tracks.first)

        #expect(first.id == "0DiWol3AO6WpXZgp0goxAV")
        #expect(first.name == "One More Time")
        #expect(first.trackNumber == 1)
        #expect(first.duration?.totalMilliseconds == 320_357)
        #expect(first.artistNames == ["Daft Punk"])
        #expect(first.firstArtistId == "4tZwfgrHOc3mvqYlEYSvVi")
    }
}

@MainActor
struct PathfinderAlbumEntityTests {
    /// Album tracks are identified by `uri` alone — there is no `id` field, unlike search's
    /// track results.
    @Test func `a track with no uri is dropped rather than keyed by nothing`() throws {
        let json = Data("""
        {"data":{"albumUnion":{"uri":"spotify:album:a","name":"A",
          "tracksV2":{"totalCount":2,"items":[
            {"track":{"name":"No uri"}},
            {"track":{"uri":"spotify:track:t2","name":"Fine"}}
          ]}}}}
        """.utf8)

        let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: json)
        let album = try #require(response.data?.albumUnion)
        let entities = try #require(album.entities())

        #expect(entities.tracks.map(\.id) == ["t2"])
        #expect(entities.album.trackIds == ["t2"])
    }

    @Test func `the album and its tracks agree on which tracks there are`() throws {
        let album = try decodeDiscovery()
        let entities = try #require(album.entities())

        #expect(entities.album.trackIds == entities.tracks.map(\.id))
        #expect(entities.album.tracksLoaded)
        #expect(entities.album.detailsLoaded)
    }

    @Test func `album details become the fields the views read`() throws {
        let entities = try #require(decodeDiscovery().entities())

        #expect(entities.album.name == "Discovery")
        #expect(entities.album.artistName == "Daft Punk")
        #expect(entities.album.artistId == "4tZwfgrHOc3mvqYlEYSvVi")
        // Lowercased: the Web API's spelling is what the views compare against.
        #expect(entities.album.albumType == "album")
        // Trimmed at the `T` — the views render a year, and the Web API sent a plain date.
        #expect(entities.album.releaseDate == "2001-03-12")
        #expect(entities.album.images.url(for: 320, scale: 2)?.absoluteString == "https://i.scdn.co/image/large")
    }

    /// The tracks carry no album of their own, so the album view's rows would have no cover art
    /// or album name unless the album's are handed down.
    @Test func `tracks inherit the album's identity and artwork`() throws {
        let entities = try #require(decodeDiscovery().entities())
        let first = try #require(entities.tracks.first)

        #expect(first.albumId == "2noRn2Aes5aoNVsU6iWThc")
        #expect(first.albumName == "Discovery")
        #expect(!first.images.isEmpty)
        #expect(first.durationMs == 320_357)
    }

    @Test func `the album's duration is the sum of its tracks`() throws {
        let entities = try #require(decodeDiscovery().entities())

        #expect(entities.album.totalDurationMs == 320_357 + 212_546)
    }

    @Test func `an album with no uri yields no entity`() throws {
        let json = Data(#"{"data":{"albumUnion":{"name":"No uri"}}}"#.utf8)
        let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: json)
        let album = try #require(response.data?.albumUnion)

        #expect(album.entities() == nil)
    }
}
