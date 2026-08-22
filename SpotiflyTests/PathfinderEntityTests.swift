//
//  PathfinderEntityTests.swift
//  SpotiflyTests
//
//  Turning pathfinder results into the entities AppStore holds.
//

import Foundation
@testable import Spotifly
import Testing

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Search has to keep rendering what it rendered before, so these check the fields
/// `SearchResultsView` actually shows.
///
/// `@MainActor` because the entities are: this target defaults to main-actor isolation, and
/// `Track` and friends are app types rather than the `nonisolated` transport types above.
@MainActor
struct PathfinderEntityMappingTests {
    @Test func `a track keeps its identity, duration and album art`() throws {
        let track = try decode(PathfinderTrack.self, """
        {"id":"t1","uri":"spotify:track:t1","name":"One More Time",
        "duration":{"totalMilliseconds":320357},
        "artists":{"items":[{"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"}}]},
        "albumOfTrack":{"id":"al1","uri":"spotify:album:al1","name":"Discovery",
        "coverArt":{"sources":[{"url":"https://i/64","width":64,"height":64},
        {"url":"https://i/640","width":640,"height":640}]}}}
        """)

        let entity = try #require(Track(pathfinder: track))

        #expect(entity.id == "t1")
        #expect(entity.name == "One More Time")
        #expect(entity.durationMs == 320_357)
        #expect(entity.artistName == "Daft Punk")
        #expect(entity.artistId == "a1")
        #expect(entity.albumId == "al1")
        #expect(entity.albumName == "Discovery")
        // Largest first, as the rest of the app expects.
        #expect(entity.images.variants.first?.size == 640)
    }

    @Test func `a track with no id is dropped rather than stored unkeyed`() throws {
        let track = try decode(PathfinderTrack.self, #"{"name":"Nameless"}"#)
        #expect(Track(pathfinder: track) == nil)
    }

    @Test func `an album derives its id from the uri and keeps the release year`() throws {
        let album = try decode(PathfinderAlbum.self, """
        {"uri":"spotify:album:al1","name":"Discovery","type":"ALBUM","date":{"year":2001},
        "artists":{"items":[{"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"}}]},
        "coverArt":{"sources":[{"url":"https://i/640","width":640,"height":640}]}}
        """)

        let entity = try #require(Album(pathfinder: album))

        #expect(entity.id == "al1")
        #expect(entity.name == "Discovery")
        #expect(entity.releaseDate == "2001")
        #expect(entity.albumType == "album")
        #expect(entity.artistName == "Daft Punk")
        // Search carries no track list, so the detail load still has work to do.
        #expect(entity.detailsLoaded == false)
        #expect(entity.trackCount == 0)
    }

    @Test func `an artist takes its name from the profile and its image from the avatar`() throws {
        let artist = try decode(PathfinderArtist.self, """
        {"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"},
        "visuals":{"avatarImage":{"sources":[{"url":"https://i/320","width":320,"height":320}]}}}
        """)

        let entity = try #require(Artist(pathfinder: artist))

        #expect(entity.id == "a1")
        #expect(entity.name == "Daft Punk")
        #expect(entity.images.variants.count == 1)
    }

    @Test func `a playlist takes its owner name for display`() throws {
        let playlist = try decode(PathfinderPlaylist.self, """
        {"uri":"spotify:playlist:p1","name":"Mix","description":"nice",
        "ownerV2":{"data":{"name":"Ralph","username":"ralph"}},
        "images":{"items":[{"sources":[{"url":"https://i/300","width":300,"height":300}]}]}}
        """)

        let entity = try #require(Playlist(pathfinder: playlist))

        #expect(entity.id == "p1")
        #expect(entity.name == "Mix")
        #expect(entity.description == "nice")
        #expect(entity.ownerName == "Ralph")
        #expect(entity.images.variants.count == 1)
    }

    @Test func `an entity with no images gets an empty set, not a broken url`() throws {
        let artist = try decode(PathfinderArtist.self, #"{"uri":"spotify:artist:a1","profile":{"name":"X"}}"#)
        let entity = try #require(Artist(pathfinder: artist))

        #expect(entity.images.variants.isEmpty)
    }

    @Test func `image sources without a usable url are skipped`() throws {
        let album = try decode(PathfinderAlbum.self, """
        {"uri":"spotify:album:al1","name":"X",
        "coverArt":{"sources":[{"width":64,"height":64},{"url":"https://i/640","width":640,"height":640}]}}
        """)

        let entity = try #require(Album(pathfinder: album))

        #expect(entity.images.variants.count == 1)
        #expect(entity.images.variants.first?.size == 640)
    }
}
