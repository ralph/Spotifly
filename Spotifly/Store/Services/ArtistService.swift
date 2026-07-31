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

    /// One run per artist ID — see `InFlightRequests`.
    private let artistRequests = InFlightRequests<Void>()

    /// The followed-artists list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-artists"

    /// How many albums an artist page shows. The endpoint is not paginated here.
    private let artistAlbumsLimit = 50

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Artists (Followed)

    /// Load the next page of followed artists, or the first if none is loaded.
    func loadUserArtists(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.artistsPagination.isLoaded, !forceRefresh, !store.artistsPagination.hasMore, !store.userArtistIds.isEmpty {
            return
        }

        if forceRefresh {
            listRequests.cancel(Self.listKey)
            store.artistsPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            // Artists use cursor-based pagination
            let cursor = self.store.artistsPagination.nextCursor
            self.store.artistsPagination.isLoading = true
            defer { self.store.artistsPagination.isLoading = false }

            let response = try await SpotifyAPI.fetchUserArtists(
                accessToken: accessToken,
                limit: 20,
                after: cursor,
            )
            // See AlbumService.loadUserAlbums: a superseded run must not write.
            try Task.checkCancellation()

            let artists = response.artists.map { Artist(from: $0) }
            self.store.upsertArtists(artists)

            let artistIds = artists.map(\.id)
            if cursor == nil {
                self.store.setUserArtistIds(artistIds)
            } else {
                self.store.appendUserArtistIds(artistIds)
            }

            self.store.artistsPagination.isLoaded = true
            self.store.artistsPagination.hasMore = response.hasMore
            self.store.artistsPagination.nextCursor = response.nextCursor
            self.store.artistsPagination.total = response.total
        }
    }

    /// Load more artists (pagination)
    func loadMoreArtists(accessToken: String) async throws {
        guard store.artistsPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
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
