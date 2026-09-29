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
/// on 2026-08-13.
///
/// The third entry is a **folder**, copied field for field from the real response rather than
/// imagined. An earlier version of this fixture guessed that a folder arrived with no `data` at
/// all, which made the "folders are dropped" test pass against a shape Spotify never sends — a
/// folder carries a `uri` and a `name` like a playlist does, decodes cleanly as one, and shipped
/// as four broken rows in the playlist list.
private let libraryFolderJSON = """
{"__typename":"Folder","uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y:folder:48e4423c174bd89d",
 "name":"¯\\\\_(ツ)_/¯","folderCount":0,"playlistCount":2}
"""
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
     "item":{"__typename":"LibraryFolderResponse",
       "_uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y:folder:48e4423c174bd89d",
       "data":\(libraryFolderJSON)}}
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

/// Liked Songs, trimmed from a real `fetchPlaylistContents` page taken on 2026-09-29 (the first
/// two of 609). A playlist page like any other, which is the point: no `_uri` wrapper, no
/// `me.library` nesting, only `content`.
private let likedSongsJSON = Data("""
{"data":{"playlistV2":{"__typename":"Playlist",
  "content":{"__typename":"PlaylistItemsPage","pagingInfo":{"limit":2,"offset":0},"totalCount":609,
  "items":[
    {"uid":"87ced089511bc3c325f3",
     "addedAt":{"isoString":"2026-09-24T15:45:46Z"},
     "itemV2":{"__typename":"TrackResponseWrapper","data":{"__typename":"Track",
       "uri":"spotify:track:7ue34ZxB8zyetZ0BCiIrn2","name":"The Diamond Church Street Choir",
       "trackNumber":4,"discNumber":1,"trackDuration":{"totalMilliseconds":192013},
       "albumOfTrack":{"uri":"spotify:album:57wwUFU2vcfs6qNDLCBnUG","name":"American Slang",
         "coverArt":{"sources":[{"height":300,"width":300,
           "url":"https://i.scdn.co/image/ab67616d00001e02c37028702ae2338a7f34175d"}]}},
       "artists":{"items":[{"uri":"spotify:artist:7If8DXZN7mlGdQkLE2FaMo",
                            "profile":{"name":"The Gaslight Anthem"}}]}}}},
    {"uid":"195f8110b593d39eb69b",
     "addedAt":{"isoString":"2026-08-15T20:13:22Z"},
     "itemV2":{"__typename":"TrackResponseWrapper","data":{"__typename":"Track",
       "uri":"spotify:track:6tuiDRFaXOBqFLpeTBjAAn","name":"Gold Lion",
       "trackNumber":1,"discNumber":1,"trackDuration":{"totalMilliseconds":187133},
       "albumOfTrack":{"uri":"spotify:album:3lgIiynXHTZYaSvS1ZrMxG","name":"Show Your Bones",
         "coverArt":{"sources":[{"height":300,"width":300,
           "url":"https://i.scdn.co/image/ab67616d00001e027e2a5058ebceafaf066eb893"}]}},
       "artists":{"items":[{"uri":"spotify:artist:3TNt4aUIxgfy9aoaft5Jj2",
                            "profile":{"name":"Yeah Yeah Yeahs"}}]}}}},
    {"uid":"0000000000000000dead",
     "itemV2":{"__typename":"TrackResponseWrapper","data":{"__typename":"Track",
       "name":"No uri, dropped"}}}
  ]}}}}
""".utf8)

private func playlistsPage() throws -> PathfinderLibraryPage<PathfinderPlaylist> {
    let response = try JSONDecoder().decode(
        PathfinderLibraryResponse<PathfinderPlaylist>.self,
        from: libraryPlaylistsJSON,
    )
    return try #require(response.page)
}

@MainActor
struct PathfinderLibraryTests {
    @Test func `the library envelope decodes down to its playlists`() throws {
        let page = try playlistsPage()

        #expect(page.totalCount == 3)
        #expect(page.items?.count == 3)
        #expect(page.entities.compactMap { Playlist(pathfinder: $0)?.name } == ["relink-test", "Second"])
    }

    /// **A folder is counted but cannot be shown**, which is why pagination advances by the
    /// item count rather than by how many playlists survived — advancing by the smaller number
    /// would re-request the difference forever and never reach the end of the list.
    @Test func `a folder decodes as a playlist and is dropped by its uri kind`() throws {
        let page = try playlistsPage()
        let folder = try #require(page.entities.last)

        // It decodes, and that is the whole problem: a folder carries a uri and a name, so
        // nothing about the *shape* rejects it.
        #expect(page.items?.count == 3)
        #expect(page.entities.count == 3)
        #expect(folder.name == "¯\\_(ツ)_/¯")

        // Only the uri's kind tells it apart, and without an id it cannot become a Playlist.
        #expect(folder.id == nil)
        #expect(Playlist(pathfinder: folder) == nil)
    }

    @Test func `a library playlist becomes the fields the list view reads`() throws {
        let first = try #require(playlistsPage().entities.first)
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

private func likedSongsPage() throws -> PathfinderPlaylistUnion.Content {
    let response = try JSONDecoder().decode(PathfinderPlaylistResponse.self, from: likedSongsJSON)
    return try #require(response.data?.playlistV2?.content)
}

@MainActor
struct LikedSongsTests {
    @Test func `a page of Liked Songs becomes its tracks, newest first`() throws {
        let page = try likedSongsPage()
        let tracks = page.tracks

        #expect(page.totalCount == 609)
        // The third row has no track uri and is dropped rather than failing the page.
        #expect(page.items?.count == 3)
        #expect(tracks.map(\.id) == ["7ue34ZxB8zyetZ0BCiIrn2", "6tuiDRFaXOBqFLpeTBjAAn"])

        let first = try #require(tracks.first)
        #expect(first.uri == "spotify:track:7ue34ZxB8zyetZ0BCiIrn2")
        #expect(first.name == "The Diamond Church Street Choir")
        #expect(first.durationMs == 192_013)
        #expect(first.trackNumber == 4)
        #expect(first.albumId == "57wwUFU2vcfs6qNDLCBnUG")
        #expect(first.albumName == "American Slang")
        #expect(first.artistId == "7If8DXZN7mlGdQkLE2FaMo")
        #expect(first.artistName == "The Gaslight Anthem")
    }

    /// The same uri for every account, asked for through the contents-only operation of the
    /// playlist document. Any other uri here would page one list and play another.
    @Test func `Liked Songs is asked for as its playlist, one page at a time`() async throws {
        let sent = Recorder<Data>()
        let api = partnerAPI { request in
            sent.record(request.httpBody ?? Data())
            return (likedSongsJSON, httpResponse(200))
        }

        let page = try await api.likedSongs(offset: 50)
        #expect(page.totalCount == 609)

        let body = try #require(sent.values.first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])
        let extensions = try #require(json["extensions"] as? [String: Any])
        let persisted = try #require(extensions["persistedQuery"] as? [String: Any])

        #expect(json["operationName"] as? String == "fetchPlaylistContents")
        #expect(persisted["sha256Hash"] as? String == PathfinderOperation.fetchPlaylist.sha256Hash)
        #expect(variables["uri"] as? String == "spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ")
        #expect(variables["offset"] as? Int == 50)
        #expect(variables["limit"] as? Int == LikedSongs.pageLimit)
    }

    @Test func `loading favorites stores the page in order and marks it saved`() async throws {
        let store = AppStore()
        let service = TrackService(
            store: store,
            partnerAPI: partnerAPI { _ in (likedSongsJSON, httpResponse(200)) },
        )

        try await service.loadFavorites()

        #expect(store.savedTrackIds == ["7ue34ZxB8zyetZ0BCiIrn2", "6tuiDRFaXOBqFLpeTBjAAn"])
        #expect(store.favoriteTracks.map(\.name) == ["The Diamond Church Street Choir", "Gold Lion"])
        #expect(store.isFavorite("6tuiDRFaXOBqFLpeTBjAAn"))
        // Three items arrived, one unreadable: the offset moves past all three.
        #expect(store.favoritesPagination.nextOffset == 3)
        #expect(store.favoritesPagination.total == 609)
        #expect(store.favoritesPagination.hasMore)
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
    private func decode(_ json: String) throws -> PathfinderLibraryMutationResponse {
        try JSONDecoder().decode(PathfinderLibraryMutationResponse.self, from: Data(json.utf8))
    }

    @Test func `a success payload reports no failure`() throws {
        for (field, typename) in [
            ("addLibraryItems", "AddLibraryItemsResponse"),
            ("removeLibraryItems", "RemoveLibraryItemsResponse"),
        ] {
            let response = try decode(#"{"data":{"\#(field)":{"__typename":"\#(typename)"}}}"#)

            #expect(response.failure == nil)
        }
    }

    /// The symmetry with the playlist mutations predicts `AddToLibraryPayload`, after
    /// `addToPlaylist` → `AddItemsToPlaylistPayload`. It is wrong, and a client that assumed it
    /// would call every successful save a rejection and roll back a write that landed.
    @Test func `the payload name the operation name suggests is not the real one`() throws {
        let response = try decode(#"{"data":{"addLibraryItems":{"__typename":"AddToLibraryPayload"}}}"#)

        #expect(response.failure != nil)
    }

    @Test func `a rejection arrives with a 200 and is still a failure`() throws {
        let response = try decode("""
        {"data":{"addLibraryItems":{"__typename":"NotFound","message":"no such uri"}}}
        """)
        let failure = try #require(response.failure)

        #expect(failure.contains("NotFound"))
        #expect(failure.contains("no such uri"))
    }

    @Test func `a response naming no result is a failure rather than a success`() throws {
        #expect(try decode(#"{"data":{}}"#).failure != nil)
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

/// The `libraryV3` variables that decide whether folders exist at all.
struct LibraryVariableTests {
    /// **The default has to be the flat one.** Measured 2026-08-13: `flatten: false` returns 14
    /// items — 10 playlists and 4 folders — and hides the 24 playlists inside those folders,
    /// while `flatten: true` with `includeFoldersWhenFlattening: false` returns all 34 and no
    /// folder. The second is what `/me/playlists` did, so it is what the app's flat list needs.
    /// Shipping the first is exactly what broke the playlist list.
    @Test func `playlists are requested flat, without folders`() throws {
        let encoded = try JSONEncoder().encode(
            PathfinderLibraryVariables(filters: [LibraryFilter.playlists]),
        )
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains("\"flatten\":true"))
        #expect(json.contains("\"includeFoldersWhenFlattening\":false"))
    }
}

/// Kind-checked uri parsing, which is what tells a playlist from a folder.
struct SpotifyURIKindTests {
    @Test func `a playlist uri yields its id`() {
        #expect(SpotifyURI.id(from: "spotify:playlist:abc", kind: "playlist") == "abc")
    }

    /// The bug in one line: taking the last component of a folder uri returns a plausible id.
    @Test func `a folder uri yields an id only without the kind check`() {
        let folder = "spotify:user:someone:folder:48e4423c174bd89d"

        #expect(SpotifyURI.id(from: folder) == "48e4423c174bd89d")
        #expect(SpotifyURI.id(from: folder, kind: "playlist") == nil)
    }

    @Test func `the wrong kind is rejected`() {
        #expect(SpotifyURI.id(from: "spotify:album:abc", kind: "playlist") == nil)
        #expect(SpotifyURI.id(from: "spotify:album:abc", kind: "album") == "abc")
    }
}
