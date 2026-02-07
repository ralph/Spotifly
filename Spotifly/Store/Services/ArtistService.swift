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

    /// Fetch artist details
    func fetchArtistDetails(artistId: String, accessToken: String) async throws -> Artist {
        let details = try await SpotifyAPI.fetchArtistDetails(
            accessToken: accessToken,
            artistId: artistId,
        )

        let artist = Artist(from: details)
        store.upsertArtist(artist)
        return artist
    }

    /// Get artist from store or fetch if needed
    func getArtist(artistId: String, accessToken: String) async throws -> Artist {
        if let artist = store.artists[artistId] {
            return artist
        }
        return try await fetchArtistDetails(artistId: artistId, accessToken: accessToken)
    }

    // MARK: - Artist Content

    /// Fetch artist's albums
    func fetchArtistAlbums(
        artistId: String,
        accessToken: String,
        limit: Int = 50,
    ) async throws -> [Album] {
        let searchAlbums = try await SpotifyAPI.fetchArtistAlbums(
            accessToken: accessToken,
            artistId: artistId,
            limit: limit,
        )

        // Convert to unified Album entities
        let albums = searchAlbums.map { Album(from: $0) }
        store.upsertAlbums(albums)

        return albums
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
