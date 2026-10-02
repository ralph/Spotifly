//
//  SearchResultsTests.swift
//  SpotiflyTests
//
//  A search's results are ids into the store's tables, so the results page follows what the
//  tables learn after the search, as every other page does.
//

@testable import Spotifly
import Testing

@MainActor
struct SearchResultsTests {
    @Test func `the results follow the tables after the search`() throws {
        let store = AppStore()
        let renamed = playlist(id: "renamed")
        let deleted = playlist(id: "deleted")
        let withheld = track(id: "withheld")
        // A search's answer: the entities in the tables, the ids in the cache.
        store.upsertPlaylists([renamed, deleted])
        store.upsertTracks([withheld])
        store.setSearchResults(
            SearchResults(albums: [], artists: [], playlists: [renamed, deleted], tracks: [withheld]),
            for: "query",
        )

        store.updatePlaylistDetails(id: "renamed", name: "New name")
        store.removePlaylistFromUserLibrary("deleted")
        store.setWithheld([withheld.uri])

        let results = try #require(store.searchResults(for: "query"))
        #expect(results.playlistIds.compactMap { store.playlists[$0] }.map(\.name) == ["New name"])
        #expect(results.trackIds.compactMap { store.tracks[$0] }.map(\.isPlayable) == [false])
    }

    @Test func `two results with one id give one row`() {
        let results = SearchResults(
            albums: [album(id: "a"), album(id: "b"), album(id: "a")],
            artists: [artist(id: "x", name: "X"), artist(id: "x", name: "X")],
            playlists: [playlist(id: "p"), playlist(id: "p")],
            tracks: [track(id: "t"), track(id: "u"), track(id: "t")],
        )

        #expect(results.albumIds == ["a", "b"])
        #expect(results.artistIds == ["x"])
        #expect(results.playlistIds == ["p"])
        #expect(results.trackIds == ["t", "u"])
    }
}
