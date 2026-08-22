//
//  PathfinderArtistTests.swift
//  SpotiflyTests
//
//  What the artist operations return, and the entities they become.
//

import Foundation
@testable import Spotifly
import Testing

/// Trimmed from a real `queryArtistOverview` response for Daft Punk, taken with the probe on
/// 2026-08-13. Note the date shape: `{day, month, year}` with **no** `isoString`, which is not
/// what `queryArtistDiscographyAll` sends.
private let overviewJSON = Data("""
{"data":{"artistUnion":{
  "__typename":"Artist",
  "id":"4tZwfgrHOc3mvqYlEYSvVi",
  "uri":"spotify:artist:4tZwfgrHOc3mvqYlEYSvVi",
  "profile":{"name":"Daft Punk","biography":{"text":"..."}},
  "visuals":{"avatarImage":{"sources":[
    {"url":"https://i.scdn.co/image/big","width":640,"height":640},
    {"url":"https://i.scdn.co/image/small","width":160,"height":160}
  ]}},
  "discography":{
    "albums":{"totalCount":15,"items":[
      {"releases":{"items":[{
        "id":"5AFf68gtvNgGLZarsyEEL8",
        "uri":"spotify:album:5AFf68gtvNgGLZarsyEEL8",
        "name":"Random Access Memories (Drumless Edition)",
        "type":"ALBUM",
        "date":{"day":17,"month":11,"year":2023,"precision":"DAY"},
        "coverArt":{"sources":[{"url":"https://i.scdn.co/image/ram","width":640,"height":640}]},
        "tracks":{"totalCount":13}
      }]}}
    ]},
    "singles":{"totalCount":21,"items":[
      {"releases":{"items":[{
        "id":"3YcIVKVDqiVvPobsotuhgx",
        "uri":"spotify:album:3YcIVKVDqiVvPobsotuhgx",
        "name":"Infinity Repeating (2013 Demo)",
        "type":"SINGLE",
        "date":{"day":11,"month":5,"year":2023,"precision":"DAY"},
        "tracks":{"totalCount":1}
      }]}}
    ]},
    "popularReleasesAlbums":{"totalCount":20,"items":[
      {"id":"5AFf68gtvNgGLZarsyEEL8","uri":"spotify:album:5AFf68gtvNgGLZarsyEEL8",
       "name":"Random Access Memories (Drumless Edition)","type":"ALBUM"}
    ]}
  }
}}}
""".utf8)

/// The discography operation, whose dates carry `isoString` instead.
private let discographyJSON = Data("""
{"data":{"artistUnion":{
  "__typename":"Artist",
  "discography":{"all":{"totalCount":37,"items":[
    {"releases":{"items":[{
      "id":"5AFf68gtvNgGLZarsyEEL8",
      "uri":"spotify:album:5AFf68gtvNgGLZarsyEEL8",
      "name":"Random Access Memories (Drumless Edition)",
      "type":"ALBUM",
      "date":{"isoString":"2023-11-17T00:00:00Z","year":2023,"precision":"DAY"},
      "tracks":{"totalCount":13}
    }]}},
    {"releases":{"items":[{
      "id":"2noRn2Aes5aoNVsU6iWThc",
      "uri":"spotify:album:2noRn2Aes5aoNVsU6iWThc",
      "name":"Discovery","type":"ALBUM",
      "date":{"isoString":"2001-03-12T00:00:00Z","year":2001,"precision":"DAY"},
      "tracks":{"totalCount":14}
    }]}}
  ]}}
}}}
""".utf8)

private func decode(_ json: Data) throws -> PathfinderArtistUnion {
    let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: json)
    return try #require(response.data?.artistUnion)
}

struct PathfinderArtistTests {
    @Test func `the overview carries the artist's identity and images`() throws {
        let artist = try decode(overviewJSON)

        #expect(artist.artistId == "4tZwfgrHOc3mvqYlEYSvVi")
        #expect(artist.profile?.name == "Daft Punk")
        #expect(artist.visuals?.avatarImage?.sources?.count == 2)
    }

    /// Releases nest as `items[].releases.items[]` — a release *group*, since one record can
    /// have several editions.
    @Test func `releases are unwrapped from their release groups`() throws {
        let artist = try decode(overviewJSON)
        let releases = artist.releases

        #expect(releases.map(\.releaseId) == ["5AFf68gtvNgGLZarsyEEL8", "3YcIVKVDqiVvPobsotuhgx"])
        #expect(releases.first?.name == "Random Access Memories (Drumless Edition)")
        #expect(releases.first?.tracks?.totalCount == 13)
    }

    /// `queryArtistOverview` dates are `{day, month, year}` and `queryArtistDiscographyAll`
    /// dates are `{isoString, year}`. One decoder absorbs both, because the artist page renders
    /// one list built from whichever operation answered.
    @Test func `both date shapes resolve to the same string`() throws {
        let fromOverview = try #require(decode(overviewJSON).releases.first?.date?.formatted)
        let fromDiscography = try #require(decode(discographyJSON).releases.first?.date?.formatted)

        #expect(fromOverview == "2023-11-17")
        #expect(fromDiscography == "2023-11-17")
    }

    @Test func `a date with only a year still yields one`() throws {
        let json = Data("""
        {"data":{"artistUnion":{"discography":{"all":{"items":[
          {"releases":{"items":[{"id":"a","uri":"spotify:album:a","name":"A",
            "date":{"year":1997,"precision":"YEAR"}}]}}
        ]}}}}}
        """.utf8)

        #expect(try decode(json).releases.first?.date?.formatted == "1997")
    }

    /// The `all` list and the sampled sections overlap, and a `ForEach` keyed by album id
    /// treats a repeat as undefined behaviour rather than a duplicate row.
    @Test func `a release listed in two sections appears once`() throws {
        let json = Data("""
        {"data":{"artistUnion":{"discography":{
          "all":{"items":[{"releases":{"items":[
            {"id":"dup","uri":"spotify:album:dup","name":"Dup"}]}}]},
          "albums":{"items":[{"releases":{"items":[
            {"id":"dup","uri":"spotify:album:dup","name":"Dup"}]}}]}
        }}}}
        """.utf8)

        #expect(try decode(json).releases.map(\.releaseId) == ["dup"])
    }

    /// `popularReleasesAlbums` puts release fields directly on `items[]` with no `releases`
    /// wrapper — measured, and the reason the item decoder accepts both. Nothing reads that
    /// section today; this pins the tolerance so a section that switches shape does not empty
    /// the artist page.
    @Test func `an item with no release wrapper is still a release`() throws {
        let json = Data("""
        {"items":[{"id":"direct","uri":"spotify:album:direct","name":"Direct","type":"ALBUM"}]}
        """.utf8)

        let group = try JSONDecoder().decode(PathfinderReleaseGroup.self, from: json)

        #expect(group.releases.map(\.releaseId) == ["direct"])
        #expect(group.releases.first?.name == "Direct")
    }
}

@MainActor
struct PathfinderArtistEntityTests {
    @Test func `the overview becomes the artist the page renders`() throws {
        let artist = try #require(Artist(pathfinderOverview: decode(overviewJSON)))

        #expect(artist.id == "4tZwfgrHOc3mvqYlEYSvVi")
        #expect(artist.name == "Daft Punk")
        #expect(artist.uri == "spotify:artist:4tZwfgrHOc3mvqYlEYSvVi")
        #expect(artist.images.url(for: 200, scale: 2)?.absoluteString == "https://i.scdn.co/image/big")
    }

    /// A discography entry has no track list, so the album is stored unloaded and opening it
    /// fetches the rest — but its track *count* is known, so the list can say "13 tracks"
    /// without that fetch.
    @Test func `a release becomes an album that knows it is not loaded`() throws {
        let release = try #require(decode(discographyJSON).releases.first)
        let album = try #require(Album(pathfinderRelease: release, artistId: "artist", artistName: "Daft Punk"))

        #expect(album.id == "5AFf68gtvNgGLZarsyEEL8")
        #expect(album.artistName == "Daft Punk")
        #expect(album.albumType == "album")
        #expect(album.releaseDate == "2023-11-17")
        // Exposed as `trackCount`, which reads the known count until the tracks are loaded.
        #expect(album.trackCount == 13)
        #expect(!album.detailsLoaded)
        #expect(album.trackIds.isEmpty)
    }

    @Test func `an artist with no id yields no entity`() throws {
        let json = Data(#"{"data":{"artistUnion":{"profile":{"name":"No id"}}}}"#.utf8)

        #expect(try Artist(pathfinderOverview: decode(json)) == nil)
    }
}
