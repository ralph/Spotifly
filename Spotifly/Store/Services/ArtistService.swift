//
//  ArtistService.swift
//  Spotifly
//
//  Service for artist-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class ArtistService {
    private let store: AppStore
    private var userArtistsTask: Task<Void, Error>?

    /// One run per artist ID — see `InFlightRequests`.
    private let artistRequests = InFlightRequests<Void>()

    /// How many albums an artist page shows. The endpoint is not paginated here.
    private let artistAlbumsLimit = 50

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Artists (Followed)

    /// Load user's followed artists
    func loadUserArtists(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.artistsPagination.isLoaded, !forceRefresh, !store.artistsPagination.hasMore, !store.userArtistIds.isEmpty {
            return
        }

        // Handle force refresh
        if forceRefresh {
            userArtistsTask?.cancel()
            userArtistsTask = nil
            store.artistsPagination.reset()
        }

        // If already loading, await existing task
        if let existingTask = userArtistsTask {
            _ = try? await existingTask.value
            return
        }

        // Create and store the loading task
        // Artists use cursor-based pagination
        let cursor = forceRefresh ? nil : store.artistsPagination.nextCursor
        store.artistsPagination.isLoading = true
        userArtistsTask = Task {
            defer {
                self.userArtistsTask = nil
                self.store.artistsPagination.isLoading = false
            }

            let response = try await SpotifyAPI.fetchUserArtists(
                accessToken: accessToken,
                limit: 20,
                after: cursor,
            )

            // Convert to unified Artist entities
            let artists = response.artists.map { Artist(from: $0) }

            // Upsert artists into store
            self.store.upsertArtists(artists)

            // Update user artist IDs
            let artistIds = artists.map(\.id)
            if forceRefresh {
                self.store.setUserArtistIds(artistIds)
            } else {
                self.store.appendUserArtistIds(artistIds)
            }

            // Update pagination state (cursor-based)
            self.store.artistsPagination.isLoaded = true
            self.store.artistsPagination.hasMore = response.hasMore
            self.store.artistsPagination.nextCursor = response.nextCursor
            self.store.artistsPagination.total = response.total
        }

        try await userArtistsTask!.value
    }

    /// Load more artists (pagination)
    func loadMoreArtists(accessToken: String) async throws {
        guard store.artistsPagination.hasMore, userArtistsTask == nil else {
            return
        }
        try await loadUserArtists(accessToken: accessToken)
    }

    // MARK: - Artist Details

    /// Makes sure the artist's details *and* their album list are in the store.
    ///
    /// The album list used to live in `ArtistDetailView`'s `@State`, so it was
    /// re-fetched on every visit and thrown away again. Now it is cached in the
    /// store like album and playlist tracks are, and a second visit issues nothing.
    /// Concurrent callers share one run, and the run outlives a caller whose view
    /// was torn down mid-flight — see `InFlightRequests`.
    func ensureArtistLoaded(artistId: String, accessToken: String) async throws {
        guard store.artists[artistId] == nil || store.artistAlbumIds[artistId] == nil else { return }

        try await artistRequests.run(artistId) {
            try await self.loadArtist(artistId: artistId, accessToken: accessToken)
        }
    }

    private func loadArtist(artistId: String, accessToken: String) async throws {
        // Re-read inside the run: a caller can arrive just as another run finishes.
        guard store.artists[artistId] != nil else {
            async let detailsTask = SpotifyAPI.fetchArtistDetails(
                accessToken: accessToken,
                artistId: artistId,
            )
            async let albumsTask = SpotifyAPI.fetchArtistAlbums(
                accessToken: accessToken,
                artistId: artistId,
                limit: artistAlbumsLimit,
            )
            let (details, artistAlbums) = try await (detailsTask, albumsTask)

            store.upsertArtist(Artist(from: details))
            storeAlbums(artistAlbums, for: artistId)
            return
        }

        guard store.artistAlbumIds[artistId] == nil else { return }

        let artistAlbums = try await SpotifyAPI.fetchArtistAlbums(
            accessToken: accessToken,
            artistId: artistId,
            limit: artistAlbumsLimit,
        )
        storeAlbums(artistAlbums, for: artistId)
    }

    /// Stores an artist's albums and records their order under the artist.
    private func storeAlbums(_ artistAlbums: [APIAlbum], for artistId: String) {
        let albums = artistAlbums.map { Album(from: $0) }
        store.upsertAlbums(albums)
        store.setArtistAlbums(albums.map(\.id), for: artistId)
    }

    // MARK: - Follow/Unfollow Artist

    /// Follow an artist (add to followed artists)
    func followArtist(artistId: String, accessToken: String) async throws {
        try await SpotifyAPI.followArtist(
            accessToken: accessToken,
            artistId: artistId,
        )

        // Update store on success
        store.addArtistToUserLibrary(artistId)
    }

    /// Unfollow an artist (remove from followed artists)
    func unfollowArtist(artistId: String, accessToken: String) async throws {
        try await SpotifyAPI.unfollowArtist(
            accessToken: accessToken,
            artistId: artistId,
        )

        // Update store on success
        store.removeArtistFromUserLibrary(artistId)
    }
}
