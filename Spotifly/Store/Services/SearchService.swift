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
    private let partner: PartnerAPI

    init(store: AppStore, partner: PartnerAPI = PartnerAPI()) {
        self.store = store
        self.partner = partner
    }

    // MARK: - Search

    /// Takes no access token: the partner API authorizes itself from the keymaster grant, which
    /// is the point of the migration. The Web API token this used to need was minted with the
    /// user's dashboard client id, and `api-partner` rejects it.
    func search(query: String) async {
        guard !query.isEmpty, !store.searchIsLoading else { return }

        store.searchIsLoading = true
        store.searchErrorMessage = nil

        do {
            let results = try await partnerSearch(query: query)

            store.setSearchResults(results, for: query)

            // Store entities in AppStore so favorites work and for future reference
            store.upsertTracks(results.tracks)
            store.upsertAlbums(results.albums)
            store.upsertArtists(results.artists)
            store.upsertPlaylists(results.playlists)
        } catch {
            store.searchErrorMessage = error.localizedDescription
        }

        store.searchIsLoading = false
    }

    /// Runs the four searches together and maps each result set into entities.
    ///
    /// Concurrently, because they are four separate operations where the Web API served all
    /// four categories from one request — sequentially this would be four round-trips of
    /// latency for what the user experiences as a single search.
    private func partnerSearch(query: String) async throws -> SearchResults {
        async let tracks = partner.searchTracks(query, limit: 20)
        async let albums = partner.searchAlbums(query, limit: 20)
        async let artists = partner.searchArtists(query, limit: 20)
        async let playlists = partner.searchPlaylists(query, limit: 20)

        return try await SearchResults(
            albums: albums.compactMap(Album.init(pathfinder:)),
            artists: artists.compactMap(Artist.init(pathfinder:)),
            playlists: playlists.compactMap(Playlist.init(pathfinder:)),
            tracks: tracks.compactMap(Track.init(pathfinder:)),
        )
    }
}
