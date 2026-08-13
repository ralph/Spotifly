//
//  PathfinderPlaylistTests.swift
//  SpotiflyTests
//
//  What `fetchPlaylist` returns, and how the mutations report success.
//

import Foundation
@testable import Spotifly
import Testing

/// Trimmed from a real `fetchPlaylist` response, taken with the probe on 2026-08-13. The second
/// item repeats the first track under a different uid, which is the case the whole `PlaylistItem`
/// change exists for.
private let playlistJSON = Data("""
{"data":{"playlistV2":{
  "__typename":"Playlist",
  "uri":"spotify:playlist:2Cngv8qX0kwH5vwkOY6wdJ",
  "name":"relink-test",
  "description":null,
  "ownerV2":{"data":{"__typename":"User","username":"qixixbr","name":"Ralph",
                     "uri":"spotify:user:qixixbr"}},
  "images":{"items":[{"sources":[{"url":"https://i.scdn.co/image/cover","width":null,"height":null}]}]},
  "content":{"totalCount":2,"items":[
    {"uid":"aaaa1111","addedAt":{"isoString":"2026-08-01T09:07:43.167Z"},
     "itemV2":{"__typename":"TrackResponseWrapper","data":{
       "uri":"spotify:track:3CCyVdprlcXui4ZwMw1hNS","name":"I Took A Pill In Ibiza",
       "trackNumber":1,"discNumber":1,
       "trackDuration":{"totalMilliseconds":280800},
       "albumOfTrack":{"uri":"spotify:album:abc123","name":"Ibiza",
                       "coverArt":{"sources":[{"url":"https://i.scdn.co/image/alb","width":640,"height":640}]}},
       "artists":{"items":[{"uri":"spotify:artist:xyz789","profile":{"name":"Mike Posner"}}]}}}},
    {"uid":"bbbb2222","addedAt":{"isoString":"2026-08-02T10:00:00.000Z"},
     "itemV2":{"__typename":"TrackResponseWrapper","data":{
       "uri":"spotify:track:3CCyVdprlcXui4ZwMw1hNS","name":"I Took A Pill In Ibiza",
       "trackNumber":1,"trackDuration":{"totalMilliseconds":280800},
       "artists":{"items":[{"uri":"spotify:artist:xyz789","profile":{"name":"Mike Posner"}}]}}}}
  ]}
}}}
""".utf8)

private func decodePlaylist() throws -> PathfinderPlaylistUnion {
    let response = try JSONDecoder().decode(PathfinderPlaylistResponse.self, from: playlistJSON)
    return try #require(response.data?.playlistV2)
}

struct PathfinderPlaylistTests {
    /// The track sits at `items[].itemV2.data` — a fourth item shape from this API, after
    /// search's `item.data`, the album's `track` and the discography's `releases.items`.
    @Test func `the playlist envelope decodes down to its tracks`() throws {
        let playlist = try decodePlaylist()

        #expect(playlist.id == "2Cngv8qX0kwH5vwkOY6wdJ")
        #expect(playlist.name == "relink-test")
        #expect(playlist.content?.totalCount == 2)
        #expect(playlist.content?.items?.first?.uid == "aaaa1111")
        #expect(playlist.content?.items?.first?.track?.name == "I Took A Pill In Ibiza")
    }
}

@MainActor
struct PathfinderPlaylistEntityTests {
    /// The point of `PlaylistItem`: one song listed twice is two rows with two uids, where the
    /// old `trackIds` array could not tell them apart at all.
    @Test func `the same track twice is two items with distinct uids`() throws {
        let entities = try #require(decodePlaylist().entities())

        #expect(entities.playlist.items.map(\.uid) == ["aaaa1111", "bbbb2222"])
        #expect(entities.playlist.items.map(\.trackId) == [
            "3CCyVdprlcXui4ZwMw1hNS", "3CCyVdprlcXui4ZwMw1hNS",
        ])
        #expect(entities.playlist.trackCount == 2)
    }

    /// Removing by uid takes one row. The Web API path removed by track uri, which took both.
    @Test func `removing one occurrence leaves the other`() throws {
        let store = AppStore()
        let entities = try #require(decodePlaylist().entities())
        store.upsertPlaylist(entities.playlist)
        store.upsertTracks(entities.tracks)

        store.removePlaylistItem(uid: "aaaa1111", playlistId: entities.playlist.id)

        #expect(store.playlists[entities.playlist.id]?.items.map(\.uid) == ["bbbb2222"])
    }

    @Test func `removing a uid the playlist does not have changes nothing`() throws {
        let store = AppStore()
        let entities = try #require(decodePlaylist().entities())
        store.upsertPlaylist(entities.playlist)

        store.removePlaylistItem(uid: "not-here", playlistId: entities.playlist.id)

        #expect(store.playlists[entities.playlist.id]?.items.count == 2)
    }

    @Test func `playlist details become the fields the views read`() throws {
        let entities = try #require(decodePlaylist().entities())

        #expect(entities.playlist.name == "relink-test")
        #expect(entities.playlist.ownerName == "Ralph")
        #expect(entities.playlist.ownerId == "qixixbr")
        #expect(entities.playlist.tracksLoaded)
        // Both occurrences count towards the duration.
        #expect(entities.playlist.totalDurationMs == 280_800 * 2)
    }

    /// Tracks in a playlist carry their own album, unlike an album's own tracks.
    @Test func `a playlist track keeps its album and artist`() throws {
        let entities = try #require(decodePlaylist().entities())
        let track = try #require(entities.tracks.first)

        #expect(track.id == "3CCyVdprlcXui4ZwMw1hNS")
        #expect(track.albumId == "abc123")
        #expect(track.albumName == "Ibiza")
        #expect(track.artistName == "Mike Posner")
        #expect(track.artistId == "xyz789")
        #expect(track.durationMs == 280_800)
    }

    /// A reorder is sent as "put this item before whatever now follows it", read out of the
    /// store *after* the optimistic move. The version this replaces mixed frames — indexing the
    /// already-reordered array with an index captured before the reorder — and so named the
    /// wrong item to move, which showed up as every dragged row landing at the end.
    @Test func `a move names the item that now follows the dragged one`() throws {
        let store = AppStore()
        let entities = try #require(decodePlaylist().entities())
        store.upsertPlaylist(entities.playlist)

        // Drag the second row above the first, as `dropEntered` would.
        store.movePlaylistTrack(playlistId: entities.playlist.id, fromIndex: 1, toIndex: 0)

        let items = try #require(store.playlists[entities.playlist.id]?.items)
        #expect(items.map(\.uid) == ["bbbb2222", "aaaa1111"])

        let movedIndex = try #require(items.firstIndex { $0.uid == "bbbb2222" })
        let beforeUid = movedIndex + 1 < items.count ? items[movedIndex + 1].uid : nil

        #expect(beforeUid == "aaaa1111")
    }

    /// Dragged to the end there is nothing to sit before, which the service spells as its own
    /// move type rather than as a position.
    @Test func `a move to the end names no following item`() throws {
        let store = AppStore()
        let entities = try #require(decodePlaylist().entities())
        store.upsertPlaylist(entities.playlist)

        store.movePlaylistTrack(playlistId: entities.playlist.id, fromIndex: 0, toIndex: 1)

        let items = try #require(store.playlists[entities.playlist.id]?.items)
        let movedIndex = try #require(items.firstIndex { $0.uid == "aaaa1111" })

        #expect(movedIndex == items.count - 1)
        #expect(movedIndex + 1 >= items.count)
    }

    @Test func `an item with no uid is dropped from both lists`() throws {
        let json = Data("""
        {"data":{"playlistV2":{"uri":"spotify:playlist:p","name":"P","content":{"totalCount":2,
          "items":[
            {"itemV2":{"data":{"uri":"spotify:track:t1","name":"No uid"}}},
            {"uid":"u2","itemV2":{"data":{"uri":"spotify:track:t2","name":"Fine"}}}
          ]}}}}
        """.utf8)
        let response = try JSONDecoder().decode(PathfinderPlaylistResponse.self, from: json)
        let union = try #require(response.data?.playlistV2)
        let entities = try #require(union.entities())

        #expect(entities.playlist.items.map(\.uid) == ["u2"])
        #expect(entities.tracks.map(\.id) == ["t2"])
    }
}

/// A rejected mutation arrives as **HTTP 200** with a failure `__typename`, so the transport's
/// status check cannot see it. Without this discrimination a failed write would look like a
/// successful one and the optimistic update would stand.
struct PathfinderMutationTests {
    @Test func `a success payload reports no failure`() throws {
        for typename in [
            "AddItemsToPlaylistPayload",
            "RemoveItemsFromPlaylistPayload",
            "MoveItemsInPlaylistPayload",
        ] {
            let json = Data(#"{"data":{"addItemsToPlaylist":{"__typename":"\#(typename)"}}}"#.utf8)
            let response = try JSONDecoder().decode(PathfinderMutationResponse.self, from: json)

            #expect(response.failure == nil)
        }
    }

    @Test func `a rejection arrives with a 200 and is still a failure`() throws {
        let json = Data("""
        {"data":{"addItemsToPlaylist":{"__typename":"NotFound",
          "message":"Object with uri 'spotify:playlist:x' not found"}}}
        """.utf8)

        let response = try JSONDecoder().decode(PathfinderMutationResponse.self, from: json)
        let failure = try #require(response.failure)

        #expect(failure.contains("NotFound"))
        #expect(failure.contains("not found"))
    }

    @Test func `a response naming no result is a failure rather than a success`() throws {
        let json = Data(#"{"data":{}}"#.utf8)
        let response = try JSONDecoder().decode(PathfinderMutationResponse.self, from: json)

        #expect(response.failure != nil)
    }

    /// The stored query references every variable it declares, so a missing one is a 400
    /// rather than a default. `enableWatchFeedEntrypoint` was omitted on the first run of this
    /// migration and the playlist page failed with nothing but a status code to go on.
    @Test func `the playlist query sends every variable its stored document declares`() throws {
        let encoded = try JSONEncoder().encode(PathfinderPlaylistVariables(uri: "spotify:playlist:p"))
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains("enableWatchFeedEntrypoint"))
        #expect(json.contains("uri"))
        #expect(json.contains("limit"))
    }

    /// `fromUid` is only meaningful for the two uid-relative moves; the service rejects those
    /// without it, which is how the enum's members were established in the first place.
    @Test func `positions encode the move type the service expects`() throws {
        let bottom = try JSONEncoder().encode(PlaylistItemPosition.bottom)
        let before = try JSONEncoder().encode(PlaylistItemPosition.before(uid: "u1"))

        let bottomJSON = try #require(String(data: bottom, encoding: .utf8))
        let beforeJSON = try #require(String(data: before, encoding: .utf8))

        #expect(bottomJSON.contains("BOTTOM_OF_PLAYLIST"))
        #expect(beforeJSON.contains("BEFORE_UID"))
        #expect(beforeJSON.contains("u1"))
    }
}
