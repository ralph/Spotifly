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
    private let defaults: UserDefaults

    /// The queries searched last, newest first, kept on this Mac only.
    private(set) var recentSearches: [String]

    /// How many recent searches are kept.
    static let recentSearchesLimit = 10
    private static let recentSearchesKey = "recentSearches"

    /// How many results a further page of one scope asks for.
    static let pageSize = 20

    /// The kinds whose further page is loading, so a second press does not ask again.
    private(set) var loadingMore: Set<SearchKind> = []

    init(store: AppStore, partner: PartnerAPI = PartnerAPI(), defaults: UserDefaults = .standard) {
        self.store = store
        self.partner = partner
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Self.recentSearchesKey) ?? []
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
            remember(query)
        } catch {
            store.setSearchFailure(error, for: query)
        }

        store.searchIsLoading = false
    }

    // MARK: - More results

    /// Loads the next page of one kind of `query`'s results and appends it.
    func loadMore(query: String, kind: SearchKind) async {
        guard !loadingMore.contains(kind),
              let results = store.searchResults(for: query), !results.exhausted.contains(kind)
        else { return }
        loadingMore.insert(kind)
        defer { loadingMore.remove(kind) }

        do {
            let page = try await fetch(kind, query: query, offset: results.nextOffset[kind] ?? 0)
            store.appendSearchResults(page.ids, to: kind, sent: page.sent, pageSize: Self.pageSize, for: query, onto: results.id)
        } catch {
            debugLog("SearchService", "More \(kind) for \(query) failed: \(error)")
        }
    }

    /// One page of one kind: searched, its entities upserted, and their ids returned with how
    /// many rows Spotify sent, unreadable ones included, which is what paging counts.
    private func fetch(_ kind: SearchKind, query: String, offset: Int) async throws -> (ids: [String], sent: Int) {
        switch kind {
        case .tracks:
            let found = try await partner.searchTracks(query, offset: offset, limit: Self.pageSize)
            let tracks = found.entities.compactMap(Track.init(pathfinder:))
            store.upsertTracks(tracks)
            return (tracks.map(\.id), found.sent)
        case .albums:
            let found = try await partner.searchAlbums(query, offset: offset, limit: Self.pageSize)
            let albums = found.entities.compactMap(Album.init(pathfinder:))
            store.upsertAlbums(albums)
            return (albums.map(\.id), found.sent)
        case .artists:
            let found = try await partner.searchArtists(query, offset: offset, limit: Self.pageSize)
            let artists = found.entities.compactMap(Artist.init(pathfinder:))
            store.upsertArtists(artists)
            return (artists.map(\.id), found.sent)
        case .playlists:
            let found = try await partner.searchPlaylists(query, offset: offset, limit: Self.pageSize)
            let playlists = found.entities.compactMap(Playlist.init(pathfinder:))
            store.upsertPlaylists(playlists)
            return (playlists.map(\.id), found.sent)
        }
    }

    // MARK: - Recent searches

    /// Puts `query` first among the recent searches, once.
    private func remember(_ query: String) {
        recentSearches.removeAll { $0 == query }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(Self.recentSearchesLimit))
        defaults.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        defaults.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        defaults.removeObject(forKey: Self.recentSearchesKey)
    }

    /// The search field was emptied. A failure is about the query that was typed, so it goes
    /// with it, and the history drops its page.
    func clearFailure() {
        store.clearSearchFailure()
    }

    /// Runs the four searches together, upserts what they found, and returns the results as ids
    /// into the tables.
    ///
    /// Concurrently, because they are four separate operations where the Web API served all
    /// four categories from one request — sequentially this would be four round-trips of
    /// latency for what the user experiences as a single search.
    private func partnerSearch(query: String) async throws -> SearchResults {
        async let tracks = fetch(.tracks, query: query, offset: 0)
        async let albums = fetch(.albums, query: query, offset: 0)
        async let artists = fetch(.artists, query: query, offset: 0)
        async let playlists = fetch(.playlists, query: query, offset: 0)

        var results = SearchResults()
        for (kind, page) in try await [(SearchKind.tracks, tracks), (.albums, albums), (.artists, artists), (.playlists, playlists)] {
            results.append(page.ids, to: kind, sent: page.sent, pageSize: Self.pageSize)
        }
        return results
    }
}
