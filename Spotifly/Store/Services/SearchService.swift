//
//  SearchService.swift
//  Spotifly
//
//  Service for search functionality.
//  Performs searches and stores returned entities in AppStore.
//

import Foundation

@MainActor
@Observable
final class SearchService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Search

    func search(accessToken: String, query: String) async {
        guard !query.isEmpty else {
            store.setSearchResults(nil)
            return
        }

        guard !store.searchIsLoading else { return }

        store.searchIsLoading = true
        store.searchErrorMessage = nil

        do {
            let results = try await SpotifyAPI.search(
                accessToken: accessToken,
                query: query,
                types: [.track, .album, .artist, .playlist],
                limit: 20,
            )

            store.setSearchResults(results)

            // Store tracks in AppStore so favorites work when displayed
            let tracks = results.tracks.map { Track(from: $0) }
            store.upsertTracks(tracks)

            // Store albums, artists, playlists for future reference
            let albums = results.albums.map { Album(from: $0) }
            store.upsertAlbums(albums)

            let artists = results.artists.map { Artist(from: $0) }
            store.upsertArtists(artists)

            let playlists = results.playlists.map { Playlist(from: $0) }
            store.upsertPlaylists(playlists)

        } catch {
            store.searchErrorMessage = error.localizedDescription
            store.setSearchResults(nil)
        }

        store.searchIsLoading = false
    }

    func clearSearch() {
        store.clearSearch()
    }
}
