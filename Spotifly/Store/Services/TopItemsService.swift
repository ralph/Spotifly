//
//  TopItemsService.swift
//  Spotifly
//
//  Service for fetching user's top artists and top tracks.
//  Fetches data from API and stores entities in AppStore.
//

import Foundation

@MainActor
@Observable
final class TopItemsService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Top Artists

    /// Load top artists (only on first call unless refresh is called)
    func loadTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard !store.topArtistsPagination.isLoaded, !store.topArtistsPagination.isLoading else { return }
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true)
    }

    /// Force refresh top artists (resets and loads first page)
    func refreshTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topArtistsPagination.reset()
        store.topArtistIds = []
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true)
    }

    /// Load more top artists (next page)
    func loadMoreTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard store.topArtistsPagination.hasMore, !store.topArtistsPagination.isLoading else { return }
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 50, isRefresh: false)
    }

    /// Fetch a single page of top artists
    private func fetchTopArtistsPage(accessToken: String, timeRange: TopItemsTimeRange, limit: Int, isRefresh: Bool) async {
        await fetchPage(
            pagination: \.topArtistsPagination,
            errorMessage: \.topArtistsErrorMessage,
        ) {
            let offset = self.store.topArtistsPagination.nextOffset ?? 0
            let response = try await SpotifyAPI.fetchUserTopArtists(
                accessToken: accessToken,
                timeRange: timeRange,
                limit: limit,
                offset: offset,
            )

            let artists = response.artists.map { Artist(from: $0) }
            self.store.upsertArtists(artists)
            let ids = artists.map(\.id)

            if isRefresh {
                self.store.topArtistIds = ids
            } else {
                self.store.topArtistIds.append(contentsOf: ids)
            }

            return PaginationResult(hasMore: response.hasMore, nextOffset: response.nextOffset, total: response.total)
        }
    }

    // MARK: - Top Tracks (for album extraction)

    /// Load top tracks and extract albums (only on first call unless refresh is called)
    func loadTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard !store.topTrackAlbumsPagination.isLoaded, !store.topTrackAlbumsPagination.isLoading else { return }
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true)
    }

    /// Force refresh top tracks and extract deduplicated albums
    func refreshTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topTrackAlbumsPagination.reset()
        store.topTrackAlbumIds = []
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true)
    }

    /// Load more top tracks (next page)
    func loadMoreTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard store.topTrackAlbumsPagination.hasMore, !store.topTrackAlbumsPagination.isLoading else { return }
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 50, isRefresh: false)
    }

    /// Fetch a single page of top tracks and extract deduplicated albums
    private func fetchTopTracksPage(accessToken: String, timeRange: TopItemsTimeRange, limit: Int, isRefresh: Bool) async {
        await fetchPage(
            pagination: \.topTrackAlbumsPagination,
            errorMessage: \.topTrackAlbumsErrorMessage,
        ) {
            let offset = self.store.topTrackAlbumsPagination.nextOffset ?? 0
            let response = try await SpotifyAPI.fetchUserTopTracks(
                accessToken: accessToken,
                timeRange: timeRange,
                limit: limit,
                offset: offset,
            )

            var newAlbumIds: [String] = []
            var seenAlbumIds = isRefresh ? Set<String>() : Set(self.store.topTrackAlbumIds)

            for apiTrack in response.tracks {
                let track = Track(from: apiTrack)
                self.store.upsertTrack(track)

                if let albumId = apiTrack.albumId, !seenAlbumIds.contains(albumId) {
                    seenAlbumIds.insert(albumId)
                    newAlbumIds.append(albumId)

                    let album = Album(
                        id: albumId,
                        name: apiTrack.albumName ?? "",
                        uri: "spotify:album:\(albumId)",
                        imageURL: apiTrack.imageURL,
                        releaseDate: nil,
                        albumType: nil,
                        externalUrl: nil,
                        artistId: apiTrack.artistId,
                        artistName: apiTrack.artistName,
                    )
                    self.store.upsertAlbum(album)
                }
            }

            if isRefresh {
                self.store.topTrackAlbumIds = newAlbumIds
            } else {
                self.store.topTrackAlbumIds.append(contentsOf: newAlbumIds)
            }

            return PaginationResult(hasMore: response.hasMore, nextOffset: response.nextOffset, total: response.total)
        }
    }

    // MARK: - Shared Pagination Helper

    /// Result of a page fetch, used to update pagination state
    private struct PaginationResult {
        let hasMore: Bool
        let nextOffset: Int?
        let total: Int
    }

    /// Shared pagination orchestration: sets loading state, clears errors, runs the fetch,
    /// updates pagination on success, or sets error on failure.
    private func fetchPage(
        pagination: ReferenceWritableKeyPath<AppStore, PaginationState>,
        errorMessage: ReferenceWritableKeyPath<AppStore, String?>,
        fetch: () async throws -> PaginationResult,
    ) async {
        store[keyPath: pagination].isLoading = true
        store[keyPath: errorMessage] = nil

        do {
            let result = try await fetch()
            store[keyPath: pagination].isLoaded = true
            store[keyPath: pagination].hasMore = result.hasMore
            store[keyPath: pagination].nextOffset = result.nextOffset
            store[keyPath: pagination].total = result.total
        } catch {
            store[keyPath: errorMessage] = error.localizedDescription
        }

        store[keyPath: pagination].isLoading = false
    }
}
