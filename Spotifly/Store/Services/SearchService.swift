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

        do {
            let found = try await partnerSearch(query: query)

            // Into the tables first: the results name them by id.
            store.upsertTracks(found.tracks)
            store.upsertAlbums(found.albums)
            store.upsertArtists(found.artists)
            store.upsertPlaylists(found.playlists)
            store.setSearchResults(
                SearchResults(albums: found.albums, artists: found.artists, playlists: found.playlists, tracks: found.tracks),
                for: query,
            )
        } catch {
            store.setSearchFailure(error, for: query)
        }

        store.searchIsLoading = false
    }

    /// Runs the four searches together and maps each result set into entities.
    ///
    /// Concurrently, because they are four separate operations where the Web API served all
    /// four categories from one request — sequentially this would be four round-trips of
    /// latency for what the user experiences as a single search.
    private func partnerSearch(
        query: String,
    ) async throws -> (albums: [Album], artists: [Artist], playlists: [Playlist], tracks: [Track]) {
        async let tracks = partner.searchTracks(query, limit: 20)
        async let albums = partner.searchAlbums(query, limit: 20)
        async let artists = partner.searchArtists(query, limit: 20)
        async let playlists = partner.searchPlaylists(query, limit: 20)

        return try await (
            albums: albums.compactMap(Album.init(pathfinder:)),
            artists: artists.compactMap(Artist.init(pathfinder:)),
            playlists: playlists.compactMap(Playlist.init(pathfinder:)),
            tracks: tracks.compactMap(Track.init(pathfinder:)),
        )
    }
}
