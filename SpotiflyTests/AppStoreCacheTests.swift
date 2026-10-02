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
        store.setPlaylistTracks([PlaylistItem(uid: "u1", trackId: "t1")], totalDurationMs: 500, for: "p")

        store.removePlaylistItem(uid: "u1", playlistId: "p")

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

    /// Everything a metadata fetch answers with.
    private func fetchedAlbum(id: String, name: String) -> Album {
        album(
            id: id,
            name: name,
            releaseDate: "2025-06-13",
            artistId: "artist",
        )
    }

    /// What `TopItemsService` can build out of a track's album object.
    private func stubAlbum(id: String, name: String) -> Album {
        album(id: id, name: name, albumType: nil, artistId: "artist", detailsLoaded: false)
    }
}

/// Spotify's playlist list answers with the literal string "null" for a playlist without a
/// description, which the detail header rendered as text.
struct PlaylistDescriptionTests {
    @Test func `a literal null description is treated as absent`() {
        #expect(String?("null").normalizedPlaylistDescription == nil)
        #expect(String?("").normalizedPlaylistDescription == nil)
        #expect(String?(nil).normalizedPlaylistDescription == nil)
        #expect(String?("Real description").normalizedPlaylistDescription == "Real description")
    }

    /// As the start page sent them on 2026-10-02.
    @Test func `a description reads as the text its HTML shows`() {
        #expect(String?("<a href=spotify:playlist:37i9dQZF1EIXPRB6OHORIn>Brian Fallon</a>, <a href=spotify:playlist:37i9dQZF1EIZN733xVL21v>The Horrible Crowes</a> und mehr").normalizedPlaylistDescription
            == "Brian Fallon, The Horrible Crowes und mehr")
        #expect(String?("a chronicle of Terri Hooley&#x27;s life").normalizedPlaylistDescription == "a chronicle of Terri Hooley's life")
        #expect(String?("Die handverlesene Playlist zum Fest & Flauschig Podcast.").normalizedPlaylistDescription
            == "Die handverlesene Playlist zum Fest & Flauschig Podcast.")
    }

    /// A `<` the user typed comes escaped, and stays a `<`; only Spotify's own tags go.
    @Test func `escaped characters come back as typed`() {
        #expect("I &lt;3 this &amp; that &quot;song&quot; &#39;99".htmlAsPlainText == "I <3 this & that \"song\" '99")
        #expect("a < b and c > d".htmlAsPlainText == "a < b and c > d")
        #expect("&unknown; &#xZZ; stays".htmlAsPlainText == "&unknown; &#xZZ; stays")
        #expect(String?("<a href=spotify:x></a>").normalizedPlaylistDescription == nil)
    }
}
