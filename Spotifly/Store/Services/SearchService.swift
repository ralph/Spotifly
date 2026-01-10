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

            // Store entities in AppStore so favorites work and for future reference
            store.upsertTracks(results.tracks)
            store.upsertAlbums(results.albums)
            store.upsertArtists(results.artists)
            store.upsertPlaylists(results.playlists)

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
