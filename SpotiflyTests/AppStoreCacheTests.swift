//
//  AppStoreCacheTests.swift
//  SpotiflyTests
//
//  The store's caching invariants: what we already know is never downgraded, and
//  a load that came back empty still counts as loaded.
//

@testable import Spotifly
import Testing

@MainActor
struct AppStoreCacheTests {
    @Test func `a stub album does not overwrite fetched metadata`() {
        let store = AppStore()
        store.upsertAlbum(fetchedAlbum(id: "a", name: "Real Name"))

        store.upsertAlbum(stubAlbum(id: "a", name: "Stub Name"))

        #expect(store.albums["a"]?.name == "Real Name")
        #expect(store.albums["a"]?.releaseDate == "2025-06-13")
        #expect(store.albums["a"]?.detailsLoaded == true)
    }

    @Test func `fetched metadata replaces a stub`() {
        let store = AppStore()
        store.upsertAlbum(stubAlbum(id: "a", name: "Stub Name"))

        store.upsertAlbum(fetchedAlbum(id: "a", name: "Real Name"))

        #expect(store.albums["a"]?.name == "Real Name")
        #expect(store.albums["a"]?.detailsLoaded == true)
    }

    @Test func `re-fetching metadata keeps loaded tracks`() {
        let store = AppStore()
        store.upsertAlbum(fetchedAlbum(id: "a", name: "Album"))
        store.setAlbumTracks(["t1", "t2"], totalDurationMs: 1000, for: "a")

        store.upsertAlbum(fetchedAlbum(id: "a", name: "Album"))

        #expect(store.albums["a"]?.trackIds == ["t1", "t2"])
        #expect(store.albums["a"]?.tracksLoaded == true)
        #expect(store.albums["a"]?.totalDurationMs == 1000)
    }

    @Test func `an album with no tracks still counts as loaded`() {
        let store = AppStore()
        store.upsertAlbum(fetchedAlbum(id: "a", name: "Album"))

        store.setAlbumTracks([], totalDurationMs: 0, for: "a")

        #expect(store.albums["a"]?.tracksLoaded == true)
        #expect(store.albums["a"]?.trackCount == 0)
    }

    @Test func `an emptied playlist still counts as loaded`() {
        let store = AppStore()
        store.upsertPlaylist(playlist(id: "p"))
        store.setPlaylistTracks(["t1"], totalDurationMs: 500, for: "p")

        store.removeTrackFromPlaylist("t1", playlistId: "p")

        #expect(store.playlists["p"]?.tracksLoaded == true)
        #expect(store.playlists["p"]?.trackIds.isEmpty == true)
    }

    @Test func `artist albums are cached in order`() {
        let store = AppStore()
        store.upsertAlbums([fetchedAlbum(id: "a2", name: "Second"), fetchedAlbum(id: "a1", name: "First")])

        #expect(store.albums(forArtist: "artist") == nil)

        store.setArtistAlbums(["a1", "a2"], for: "artist")

        #expect(store.albums(forArtist: "artist")?.map(\.name) == ["First", "Second"])
    }

    // MARK: - Fixtures

    private func fetchedAlbum(id: String, name: String) -> Album {
        Album(
            id: id,
            name: name,
            uri: "spotify:album:\(id)",
            images: .empty,
            releaseDate: "2025-06-13",
            albumType: "album",
            externalUrl: "https://open.spotify.com/album/\(id)",
            artistId: "artist",
            artistName: "Artist",
            detailsLoaded: true,
        )
    }

    /// What `TopItemsService` can build out of a track's album object.
    private func stubAlbum(id: String, name: String) -> Album {
        Album(
            id: id,
            name: name,
            uri: "spotify:album:\(id)",
            images: .empty,
            releaseDate: nil,
            albumType: nil,
            externalUrl: nil,
            artistId: "artist",
            artistName: "Artist",
            detailsLoaded: false,
        )
    }

    private func playlist(id: String) -> Playlist {
        Playlist(
            id: id,
            name: "Playlist",
            description: nil,
            images: .empty,
            uri: "spotify:playlist:\(id)",
            isPublic: true,
            ownerId: "owner",
            ownerName: "Owner",
        )
    }
}
