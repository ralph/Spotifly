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

    /// In-flight loads keyed by the pagination they drive (top artists vs. top
    /// tracks). Stored so concurrent callers await the same load instead of starting
    /// a new one, and — because they're unstructured Tasks — so a load survives
    /// cancellation of the caller's `.task`. Mirrors the library services.
    private var loadTasks: [AnyKeyPath: Task<Void, Never>] = [:]

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Top Artists

    /// Load top artists (only on first call unless refresh is called)
    func loadTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard !store.topArtistsPagination.isLoaded else { return }
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true, forceRefresh: false)
    }

    /// Force refresh top artists (resets and loads first page)
    func refreshTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topArtistsPagination.reset()
        store.topArtistIds = []
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true, forceRefresh: true)
    }

    /// Load more top artists (next page)
    func loadMoreTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard store.topArtistsPagination.hasMore, !store.topArtistsPagination.isLoading else { return }
        await fetchTopArtistsPage(accessToken: accessToken, timeRange: timeRange, limit: 50, isRefresh: false, forceRefresh: false)
    }

    /// Fetch a single page of top artists
    private func fetchTopArtistsPage(accessToken: String, timeRange: TopItemsTimeRange, limit: Int, isRefresh: Bool, forceRefresh: Bool) async {
        await fetchPage(
            pagination: \.topArtistsPagination,
            errorMessage: \.topArtistsErrorMessage,
            forceRefresh: forceRefresh,
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
        guard !store.topTrackAlbumsPagination.isLoaded else { return }
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true, forceRefresh: false)
    }

    /// Force refresh top tracks and extract deduplicated albums
    func refreshTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topTrackAlbumsPagination.reset()
        store.topTrackAlbumIds = []
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 15, isRefresh: true, forceRefresh: true)
    }

    /// Load more top tracks (next page)
    func loadMoreTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard store.topTrackAlbumsPagination.hasMore, !store.topTrackAlbumsPagination.isLoading else { return }
        await fetchTopTracksPage(accessToken: accessToken, timeRange: timeRange, limit: 50, isRefresh: false, forceRefresh: false)
    }

    /// Fetch a single page of top tracks and extract deduplicated albums
    private func fetchTopTracksPage(accessToken: String, timeRange: TopItemsTimeRange, limit: Int, isRefresh: Bool, forceRefresh: Bool) async {
        await fetchPage(
            pagination: \.topTrackAlbumsPagination,
            errorMessage: \.topTrackAlbumsErrorMessage,
            forceRefresh: forceRefresh,
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

                    // A stub built from the track's album object: enough to render
                    // the top-albums row, but missing release date, album type and
                    // external URL. `detailsLoaded` stays false so opening it still
                    // fetches the real metadata, and so it cannot overwrite a fully
                    // fetched album already in the store.
                    let album = Album(
                        id: albumId,
                        name: apiTrack.albumName ?? "",
                        uri: "spotify:album:\(albumId)",
                        images: apiTrack.images,
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

    /// Shared pagination orchestration: dedups against any in-flight load for the
    /// same pagination, sets loading state, clears errors, runs the fetch in an
    /// unstructured task (so it survives caller cancellation), and updates
    /// pagination on success or sets error on failure.
    private func fetchPage(
        pagination: ReferenceWritableKeyPath<AppStore, PaginationState>,
        errorMessage: ReferenceWritableKeyPath<AppStore, String?>,
        forceRefresh: Bool,
        fetch: @escaping () async throws -> PaginationResult,
    ) async {
        // Force refresh cancels any in-flight load and starts over
        if forceRefresh {
            loadTasks[pagination]?.cancel()
            loadTasks[pagination] = nil
        }

        // If a load is already in flight, await it instead of starting a new one.
        if let existingTask = loadTasks[pagination] {
            await existingTask.value
            return
        }

        store[keyPath: pagination].isLoading = true
        store[keyPath: errorMessage] = nil

        let task = Task {
            defer {
                self.loadTasks[pagination] = nil
                self.store[keyPath: pagination].isLoading = false
            }
            do {
                let result = try await fetch()
                self.store[keyPath: pagination].isLoaded = true
                self.store[keyPath: pagination].hasMore = result.hasMore
                self.store[keyPath: pagination].nextOffset = result.nextOffset
                self.store[keyPath: pagination].total = result.total
            } catch {
                self.store[keyPath: errorMessage] = error.localizedDescription
            }
        }
        loadTasks[pagination] = task
        await task.value
    }
}
