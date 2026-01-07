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

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Artists (Followed)

    /// Load user's followed artists
    func loadUserArtists(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh
        if store.artistsPagination.isLoaded, !forceRefresh, !store.artistsPagination.hasMore {
            return
        }

        // Reset pagination on force refresh
        if forceRefresh {
            store.artistsPagination.reset()
        }

        guard !store.artistsPagination.isLoading else { return }
        store.artistsPagination.isLoading = true

        defer { store.artistsPagination.isLoading = false }

        // Artists use cursor-based pagination
        let cursor = forceRefresh ? nil : store.artistsPagination.nextCursor

        let response = try await SpotifyAPI.fetchUserArtists(
            accessToken: accessToken,
            limit: 20,
            after: cursor,
        )

        // Convert to unified Artist entities
        let artists = response.artists.map { Artist(from: $0) }

        // Upsert artists into store
        store.upsertArtists(artists)

        // Update user artist IDs
        let artistIds = artists.map(\.id)
        if forceRefresh {
            store.setUserArtistIds(artistIds)
        } else {
            store.appendUserArtistIds(artistIds)
        }

        // Update pagination state (cursor-based)
        store.artistsPagination.isLoaded = true
        store.artistsPagination.hasMore = response.hasMore
        store.artistsPagination.nextCursor = response.nextCursor
        store.artistsPagination.total = response.total
    }

    /// Load more artists (pagination)
    func loadMoreArtists(accessToken: String) async throws {
        guard store.artistsPagination.hasMore, !store.artistsPagination.isLoading else {
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

    /// Fetch artist's top tracks
    func fetchArtistTopTracks(artistId: String, accessToken: String) async throws -> [Track] {
        let searchTracks = try await SpotifyAPI.fetchArtistTopTracks(
            accessToken: accessToken,
            artistId: artistId,
        )

        // Convert to unified Track entities
        let tracks = searchTracks.map { Track(from: $0) }
        store.upsertTracks(tracks)

        return tracks
    }

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
}
