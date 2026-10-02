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
            try await store.setSearchResults(partnerSearch(query: query), for: query)
        } catch {
            store.setSearchFailure(error, for: query)
        }

        store.searchIsLoading = false
    }

    /// Runs the four searches together, upserts what they found, and returns the results as ids
    /// into the tables.
    ///
    /// Concurrently, because they are four separate operations where the Web API served all
    /// four categories from one request — sequentially this would be four round-trips of
    /// latency for what the user experiences as a single search.
    private func partnerSearch(query: String) async throws -> SearchResults {
        async let trackAnswer = partner.searchTracks(query, limit: 20)
        async let albumAnswer = partner.searchAlbums(query, limit: 20)
        async let artistAnswer = partner.searchArtists(query, limit: 20)
        async let playlistAnswer = partner.searchPlaylists(query, limit: 20)

        let tracks = try await trackAnswer.compactMap(Track.init(pathfinder:))
        let albums = try await albumAnswer.compactMap(Album.init(pathfinder:))
        let artists = try await artistAnswer.compactMap(Artist.init(pathfinder:))
        let playlists = try await playlistAnswer.compactMap(Playlist.init(pathfinder:))

        store.upsertTracks(tracks)
        store.upsertAlbums(albums)
        store.upsertArtists(artists)
        store.upsertPlaylists(playlists)
        return SearchResults(albums: albums, artists: artists, playlists: playlists, tracks: tracks)
    }
}
