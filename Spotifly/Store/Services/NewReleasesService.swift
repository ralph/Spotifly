//
//  NewReleasesService.swift
//  Spotifly
//
//  Service for fetching new album releases.
//  Fetches data from API and stores entities in AppStore.
//

import Foundation

@MainActor
@Observable
final class NewReleasesService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - New Releases

    /// Load new releases (only on first call unless refresh is called)
    func loadNewReleases(accessToken: String) async {
        guard !store.hasLoadedNewReleases else { return }
        store.hasLoadedNewReleases = true
        await refresh(accessToken: accessToken)
    }

    /// Force refresh new releases
    func refresh(accessToken: String) async {
        store.newReleasesIsLoading = true
        store.newReleasesErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchNewReleases(
                accessToken: accessToken,
                limit: 20,
            )

            // Convert to entities and store
            let albums = response.albums.map { Album(from: $0) }
            store.upsertAlbums(albums)
            store.setNewReleaseAlbumIds(albums.map(\.id))

        } catch {
            store.newReleasesErrorMessage = error.localizedDescription
        }

        store.newReleasesIsLoading = false
    }
}
