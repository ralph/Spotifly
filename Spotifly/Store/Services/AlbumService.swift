//
//  AlbumService.swift
//  Spotifly
//
//  Service for album-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class AlbumService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Albums

    /// Load user's saved albums
    func loadUserAlbums(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh
        if store.albumsPagination.isLoaded, !forceRefresh, !store.albumsPagination.hasMore {
            return
        }

        // Reset pagination on force refresh
        if forceRefresh {
            store.albumsPagination.reset()
        }

        guard !store.albumsPagination.isLoading else { return }
        store.albumsPagination.isLoading = true

        defer { store.albumsPagination.isLoading = false }

        let offset = forceRefresh ? 0 : (store.albumsPagination.nextOffset ?? 0)

        let response = try await SpotifyAPI.fetchUserAlbums(
            accessToken: accessToken,
            limit: 50,
            offset: offset,
        )

        // Convert to unified Album entities
        let albums = response.albums.map { Album(from: $0) }

        // Upsert albums into store
        store.upsertAlbums(albums)

        // Update user album IDs
        let albumIds = albums.map(\.id)
        if forceRefresh {
            store.setUserAlbumIds(albumIds)
        } else {
            store.appendUserAlbumIds(albumIds)
        }

        // Update pagination state
        store.albumsPagination.isLoaded = true
        store.albumsPagination.hasMore = response.hasMore
        store.albumsPagination.nextOffset = response.nextOffset
        store.albumsPagination.total = response.total
    }

    /// Load more albums (pagination)
    func loadMoreAlbums(accessToken: String) async throws {
        guard store.albumsPagination.hasMore, !store.albumsPagination.isLoading else {
            return
        }
        try await loadUserAlbums(accessToken: accessToken)
    }

    // MARK: - Album Details

    /// Fetch album details and tracks
    func fetchAlbumDetails(albumId: String, accessToken: String) async throws -> Album {
        // Fetch details and tracks in parallel
        async let detailsTask = SpotifyAPI.fetchAlbumDetails(
            accessToken: accessToken,
            albumId: albumId,
        )
        async let tracksTask = SpotifyAPI.fetchAlbumTracks(
            accessToken: accessToken,
            albumId: albumId,
        )

        let (details, albumTracks) = try await (detailsTask, tracksTask)

        // Convert tracks to unified entities with album context
        let tracks = albumTracks.map { albumTrack in
            Track(
                from: albumTrack,
                albumId: details.id,
                albumName: details.name,
                imageURL: details.imageURL,
            )
        }
        store.upsertTracks(tracks)

        // Calculate total duration
        let totalDurationMs = tracks.reduce(0) { $0 + $1.durationMs }

        // Create album with track IDs
        let album = Album(
            from: details,
            trackIds: tracks.map(\.id),
            totalDurationMs: totalDurationMs,
        )

        store.upsertAlbum(album)
        return album
    }

    /// Get tracks for an album (from store or fetch)
    func getAlbumTracks(albumId: String, accessToken: String) async throws -> [Track] {
        // Check if tracks are already loaded
        if let album = store.albums[albumId], album.tracksLoaded {
            return album.trackIds.compactMap { store.tracks[$0] }
        }

        // Fetch album details (which includes tracks)
        let album = try await fetchAlbumDetails(albumId: albumId, accessToken: accessToken)
        return album.trackIds.compactMap { store.tracks[$0] }
    }

    /// Get album from store or fetch if needed
    func getAlbum(albumId: String, accessToken: String) async throws -> Album {
        if let album = store.albums[albumId] {
            return album
        }
        return try await fetchAlbumDetails(albumId: albumId, accessToken: accessToken)
    }
}
