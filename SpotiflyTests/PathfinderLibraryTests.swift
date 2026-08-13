//
//  PathfinderLibraryTests.swift
//  SpotiflyTests
//
//  What the library operations return, and the three ways their shapes differ from every
//  other pathfinder response.
//

import Foundation
@testable import Spotifly
import Testing

/// Trimmed from a real `libraryV3` response with `filters: ["Playlists"]`, taken with the probe
/// on 2026-08-13. The third entry is a **folder** — a library item with no playlist under it,
/// which the account in testing had four of.
private let libraryPlaylistsJSON = Data("""
{"data":{"me":{"libraryV3":{
  "__typename":"LibraryPage",
  "totalCount":3,
  "items":[
    {"addedAt":{"isoString":"2026-08-01T09:07:43.019Z"},"pinned":false,
     "item":{"__typename":"LibraryPlaylistResponse","_uri":"spotify:playlist:2Cngv8qX0kwH5vwkOY6wdJ",
       "data":{"__typename":"Playlist","uri":"spotify:playlist:2Cngv8qX0kwH5vwkOY6wdJ",
         "name":"relink-test","description":null,
         "images":{"items":[{"sources":[{"url":"https://i.scdn.co/image/cover","width":null,"height":null}]}]},
         "ownerV2":{"data":{"__typename":"User","username":"qixixbr0ox6sik6jc6bkv6y6y",
                            "name":"llralphj"}}}}},
    {"addedAt":{"isoString":"2026-07-02T10:00:00Z"},"pinned":true,
     "item":{"__typename":"LibraryPlaylistResponse","_uri":"spotify:playlist:6bhqYKPyoohraJKQjSOpMe",
       "data":{"__typename":"Playlist","uri":"spotify:playlist:6bhqYKPyoohraJKQjSOpMe",
         "name":"Second","ownerV2":{"data":{"username":"someone","name":"Someone"}}}}},
    {"addedAt":{"isoString":"2026-06-01T10:00:00Z"},"pinned":false,
     "item":{"__typename":"LibraryFolderResponse","_uri":"spotify:folder:abc"}}
  ]}}}}
""".utf8)

/// From `filters: ["Albums"]`. Note `date` is an `isoString` here, where a *search* result
/// carries only `{year}` — the same `PathfinderAlbum` type serves both.
private let libraryAlbumsJSON = Data("""
{"data":{"me":{"libraryV3":{
  "totalCount":1,
  "items":[
    {"addedAt":{"isoString":"2025-05-08T22:00:00Z"},"pinned":false,
     "item":{"_uri":"spotify:album:4ifWQZN7li3ij532LR1l0q",
       "data":{"__typename":"Album","uri":"spotify:album:4ifWQZN7li3ij532LR1l0q",
         "name":"Never/Know","type":"ALBUM",
         "date":{"isoString":"2025-05-09T00:00:00Z","precision":"DAY"},
         "artists":{"items":[{"uri":"spotify:artist:1GLtl8uqKmnyCWxHmw9tL4",
                              "profile":{"name":"The Kooks"}}]},
         "coverArt":{"sources":[{"url":"https://i.scdn.co/image/alb","width":640,"height":640}]}}}}
  ]}}}}
""".utf8)

/// From `fetchLibraryTracks`. The uri is on the wrapper as `_uri`; the entity below it has
/// none, which is unique to this operation.
private let libraryTracksJSON = Data("""
{"data":{"me":{"library":{"tracks":{
  "__typename":"UserLibraryTrackPage",
  "totalCount":607,
  "items":[
    {"__typename":"UserLibraryTrackResponse",
     "addedAt":{"isoString":"2026-08-13T07:12:40Z"},
     "track":{"_uri":"spotify:track:7FcObTmCbQYyC8qzlTL2SE",
       "data":{"__typename":"Track","name":"Food In The Belly",
         "trackNumber":3,"discNumber":1,
         "duration":{"totalMilliseconds":251293},
         "albumOfTrack":{"uri":"spotify:album:3daDaRtJ2vfqBLwMYEgRrn","name":"Food In The Belly",
           "coverArt":{"sources":[{"url":"https://i.scdn.co/image/x","width":640,"height":640}]},
           "artists":{"items":[{"uri":"spotify:artist:5lbM4g6bhxjNX7R5QHP2nD",
                                "profile":{"name":"Xavier Rudd"}}]}},
         "artists":{"items":[{"uri":"spotify:artist:5lbM4g6bhxjNX7R5QHP2nD",
                              "profile":{"name":"Xavier Rudd"}}]}}}},
    {"__typename":"UserLibraryTrackResponse","addedAt":{"isoString":"2026-08-12T07:12:40Z"},
     "track":{"data":{"__typename":"Track","name":"No uri, dropped"}}}
  ]}}}}}
""".utf8)

@MainActor
struct PathfinderLibraryTests {
    @Test func `the library envelope decodes down to its playlists`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryResponse<PathfinderPlaylist>.self,
            from: libraryPlaylistsJSON,
        )
        let page = try #require(response.page)

        #expect(page.totalCount == 3)
        #expect(page.items?.count == 3)
        #expect(page.entities.map(\.name) == ["relink-test", "Second"])
    }

    /// **A folder is counted but cannot be shown.** `totalCount` is 3 for two playlists, which
    /// is why pagination advances by the item count rather than the entity count — advancing by
    /// two would re-request the third entry forever and never reach the end of the list.
    @Test func `a folder is an item with no entity under it`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryResponse<PathfinderPlaylist>.self,
            from: libraryPlaylistsJSON,
        )
        let page = try #require(response.page)

        #expect(page.items?.count == 3)
        #expect(page.entities.count == 2)
        #expect(page.items?.last?.item?.data == nil)
    }

    @Test func `a library playlist becomes the fields the list view reads`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryResponse<PathfinderPlaylist>.self,
            from: libraryPlaylistsJSON,
        )
        let first = try #require(response.page?.entities.first)
        let playlist = try #require(Playlist(pathfinder: first))

        #expect(playlist.id == "2Cngv8qX0kwH5vwkOY6wdJ")
        #expect(playlist.name == "relink-test")
        // Ownership decides whether the edit controls appear, and is compared against the
        // logged-in user's id — which is what `username` holds here.
        #expect(playlist.ownerId == "qixixbr0ox6sik6jc6bkv6y6y")
        #expect(playlist.ownerName == "llralphj")
    }

    /// The library and search return the same `PathfinderAlbum` with **different date shapes** —
    /// `{isoString}` here, `{year}` from search. A decoder written against either alone leaves
    /// the other's albums with no release date.
    @Test func `a library album keeps its release date`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryResponse<PathfinderAlbum>.self,
            from: libraryAlbumsJSON,
        )
        let first = try #require(response.page?.entities.first)
        let album = try #require(Album(pathfinder: first))

        #expect(album.id == "4ifWQZN7li3ij532LR1l0q")
        #expect(album.name == "Never/Know")
        #expect(album.releaseDate == "2025-05-09")
        #expect(album.albumType == "album")
        #expect(album.artistName == "The Kooks")
    }

    @Test func `a search album still resolves its year-only date`() throws {
        let json = Data(#"{"uri":"spotify:album:a","name":"A","date":{"year":2001}}"#.utf8)
        let album = try JSONDecoder().decode(PathfinderAlbum.self, from: json)

        #expect(album.date?.formatted == "2001")
    }
}

@MainActor
struct PathfinderLibraryTrackTests {
    /// **The uri is on the wrapper, not the entity.** Reading `data.uri` would be nil for every
    /// row and silently empty the favorites list, so the conversion takes the uri as a parameter.
    @Test func `a saved track takes its identity from the wrapper's uri`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryTracksResponse.self,
            from: libraryTracksJSON,
        )
        let page = try #require(response.page)
        let track = try #require(page.tracks.first)

        #expect(page.totalCount == 607)
        #expect(track.id == "7FcObTmCbQYyC8qzlTL2SE")
        #expect(track.uri == "spotify:track:7FcObTmCbQYyC8qzlTL2SE")
        #expect(track.name == "Food In The Belly")
        #expect(track.durationMs == 251_293)
        #expect(track.trackNumber == 3)
        #expect(track.albumId == "3daDaRtJ2vfqBLwMYEgRrn")
        #expect(track.artistName == "Xavier Rudd")
        #expect(track.artistId == "5lbM4g6bhxjNX7R5QHP2nD")
    }

    @Test func `a row with no uri is dropped rather than failing the page`() throws {
        let response = try JSONDecoder().decode(
            PathfinderLibraryTracksResponse.self,
            from: libraryTracksJSON,
        )
        let page = try #require(response.page)

        #expect(page.items?.count == 2)
        #expect(page.tracks.count == 1)
    }
}

/// `areEntitiesInLibrary` answers **positionally** — nothing in the response names the uri it is
/// about — so the request order is the only thing tying answers to questions.
struct PathfinderLibraryMembershipTests {
    private func decode(_ json: String) throws -> PathfinderLibraryMembershipResponse {
        try JSONDecoder().decode(
            PathfinderLibraryMembershipResponse.self,
            from: Data(json.utf8),
        )
    }

    @Test func `answers are matched to the uris that asked them, by position`() throws {
        let response = try decode("""
        {"data":{"lookup":[
          {"__typename":"TrackResponseWrapper","data":{"__typename":"Track","saved":true}},
          {"__typename":"TrackResponseWrapper","data":{"__typename":"Track","saved":false}}
        ]}}
        """)

        let statuses = response.statuses(for: ["spotify:track:aaa", "spotify:track:bbb"])

        #expect(statuses == ["aaa": true, "bbb": false])
    }

    /// A uri that resolves to nothing comes back as `NotFound` with no `saved` field, which is
    /// the same answer `/v1/me/tracks/contains` gave for an id it did not know.
    @Test func `a uri that resolves to nothing reads as not saved`() throws {
        let response = try decode("""
        {"data":{"lookup":[
          {"__typename":"TrackResponseWrapper","data":{"__typename":"NotFound"}}
        ]}}
        """)

        #expect(response.statuses(for: ["spotify:track:nowhere"]) == ["nowhere": false])
    }

    /// **A short answer must not be padded.** Fewer answers than questions leaves the
    /// unanswered uris out entirely, so they stay unresolved and get asked about again —
    /// rather than being cached as "not a favorite" on the strength of a truncated response.
    @Test func `unanswered uris are left out rather than defaulted`() throws {
        let response = try decode("""
        {"data":{"lookup":[
          {"__typename":"TrackResponseWrapper","data":{"__typename":"Track","saved":true}}
        ]}}
        """)

        let statuses = response.statuses(for: ["spotify:track:aaa", "spotify:track:bbb"])

        #expect(statuses == ["aaa": true])
        #expect(statuses["bbb"] == nil)
    }
}

/// The library writes report failure the same way the playlist ones do — HTTP 200 with a
/// `__typename` — but under **different names than the operation**, which is the part that
/// cannot be guessed.
struct PathfinderLibraryMutationTests {
    @Test func `a success payload reports no failure`() throws {
        for (field, typename) in [
            ("addLibraryItems", "AddLibraryItemsResponse"),
            ("removeLibraryItems", "RemoveLibraryItemsResponse"),
        ] {
            let json = Data(#"{"data":{"\#(field)":{"__typename":"\#(typename)"}}}"#.utf8)
            let response = try JSONDecoder().decode(
                PathfinderLibraryMutationResponse.self,
                from: json,
            )

            #expect(response.failure == nil)
        }
    }

    /// The symmetry with the playlist mutations predicts `AddToLibraryPayload`, after
    /// `addToPlaylist` → `AddItemsToPlaylistPayload`. It is wrong, and a client that assumed it
    /// would call every successful save a rejection and roll back a write that landed.
    @Test func `the payload name the operation name suggests is not the real one`() throws {
        let json = Data(#"{"data":{"addLibraryItems":{"__typename":"AddToLibraryPayload"}}}"#.utf8)
        let response = try JSONDecoder().decode(
            PathfinderLibraryMutationResponse.self,
            from: json,
        )

        #expect(response.failure != nil)
    }

    @Test func `a rejection arrives with a 200 and is still a failure`() throws {
        let json = Data("""
        {"data":{"addLibraryItems":{"__typename":"NotFound","message":"no such uri"}}}
        """.utf8)

        let response = try JSONDecoder().decode(
            PathfinderLibraryMutationResponse.self,
            from: json,
        )
        let failure = try #require(response.failure)

        #expect(failure.contains("NotFound"))
        #expect(failure.contains("no such uri"))
    }

    @Test func `a response naming no result is a failure rather than a success`() throws {
        let json = Data(#"{"data":{}}"#.utf8)
        let response = try JSONDecoder().decode(
            PathfinderLibraryMutationResponse.self,
            from: json,
        )

        #expect(response.failure != nil)
    }
}

/// Pagination arithmetic the Web API used to do for us.
///
/// `/me/tracks` answered with a `next` URL that was null on the last page, so a client only had
/// to look. The client APIs report a `totalCount` and leave the sums here, which introduces two
/// ways to get it wrong that could not happen before.
@MainActor
struct PaginationAdvanceTests {
    @Test func `the offset advances by what arrived`() {
        var state = PaginationState()

        state.advance(by: 50, total: 120)

        #expect(state.nextOffset == 50)
        #expect(state.total == 120)
        #expect(state.hasMore)
    }

    @Test func `the list ends when the offset reaches the total`() {
        var state = PaginationState()
        state.advance(by: 50, total: 60)
        state.advance(by: 10, total: 60)

        #expect(state.nextOffset == 60)
        #expect(!state.hasMore)
    }

    /// **The end of a list Spotify overcounts.** A `Playlists` page reports folders in its
    /// total and cannot render them, so the offset can never reach `totalCount`. Without this,
    /// `hasMore` would stay true and the list view would ask for another page forever.
    @Test func `an empty page ends the list whatever the total claims`() {
        var state = PaginationState()
        state.advance(by: 14, total: 20)
        #expect(state.hasMore)

        state.advance(by: 0, total: 20)

        #expect(!state.hasMore)
        #expect(state.nextOffset == 14)
    }

    @Test func `a reset puts the list back to its first page`() {
        var state = PaginationState()
        state.advance(by: 50, total: 120)
        state.isLoaded = true

        state.reset()

        #expect(state.nextOffset == 0)
        #expect(state.total == 0)
        #expect(state.hasMore)
        #expect(!state.isLoaded)
    }
}
