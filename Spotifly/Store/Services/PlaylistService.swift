//
//  PlaylistService.swift
//  Spotifly
//
//  Service for playlist-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class PlaylistService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Playlists

    /// Load user's playlists
    func loadUserPlaylists(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh
        if store.playlistsPagination.isLoaded, !forceRefresh, !store.playlistsPagination.hasMore {
            return
        }

        // Reset pagination on force refresh
        if forceRefresh {
            store.playlistsPagination.reset()
        }

        guard !store.playlistsPagination.isLoading else { return }
        store.playlistsPagination.isLoading = true

        defer { store.playlistsPagination.isLoading = false }

        let offset = forceRefresh ? 0 : (store.playlistsPagination.nextOffset ?? 0)

        let response = try await SpotifyAPI.fetchUserPlaylists(
            accessToken: accessToken,
            limit: 50,
            offset: offset,
        )

        // Convert to unified Playlist entities
        let playlists = response.playlists.map { Playlist(from: $0) }

        // Upsert playlists into store
        store.upsertPlaylists(playlists)

        // Update user playlist IDs
        let playlistIds = playlists.map(\.id)
        if forceRefresh {
            store.setUserPlaylistIds(playlistIds)
        } else {
            store.appendUserPlaylistIds(playlistIds)
        }

        // Update pagination state
        store.playlistsPagination.isLoaded = true
        store.playlistsPagination.hasMore = response.hasMore
        store.playlistsPagination.nextOffset = response.nextOffset
        store.playlistsPagination.total = response.total
    }

    /// Load more playlists (pagination)
    func loadMorePlaylists(accessToken: String) async throws {
        guard store.playlistsPagination.hasMore, !store.playlistsPagination.isLoading else {
            return
        }
        try await loadUserPlaylists(accessToken: accessToken)
    }

    // MARK: - Playlist Details

    /// Fetch playlist details and tracks
    func fetchPlaylistDetails(playlistId: String, accessToken: String) async throws -> Playlist {
        // Fetch details and tracks in parallel
        async let detailsTask = SpotifyAPI.fetchPlaylistDetails(
            accessToken: accessToken,
            playlistId: playlistId,
        )
        async let tracksTask = SpotifyAPI.fetchPlaylistTracks(
            accessToken: accessToken,
            playlistId: playlistId,
        )

        let (details, playlistTracks) = try await (detailsTask, tracksTask)

        // Convert tracks to unified entities and store them
        let tracks = playlistTracks.map { Track(from: $0) }
        store.upsertTracks(tracks)

        // Calculate total duration
        let totalDurationMs = tracks.reduce(0) { $0 + $1.durationMs }

        // Create playlist with track IDs
        let playlist = Playlist(
            from: details,
            trackIds: tracks.map(\.id),
            totalDurationMs: totalDurationMs,
        )

        store.upsertPlaylist(playlist)
        return playlist
    }

    /// Get tracks for a playlist (from store or fetch)
    func getPlaylistTracks(playlistId: String, accessToken: String) async throws -> [Track] {
        // Check if tracks are already loaded
        if let playlist = store.playlists[playlistId], playlist.tracksLoaded {
            return playlist.trackIds.compactMap { store.tracks[$0] }
        }

        // Fetch playlist details (which includes tracks)
        let playlist = try await fetchPlaylistDetails(playlistId: playlistId, accessToken: accessToken)
        return playlist.trackIds.compactMap { store.tracks[$0] }
    }

    // MARK: - Playlist Mutations

    /// Create a new playlist
    func createPlaylist(
        userId: String,
        name: String,
        description: String? = nil,
        accessToken: String,
    ) async throws -> Playlist {
        let response = try await SpotifyAPI.createPlaylist(
            accessToken: accessToken,
            userId: userId,
            name: name,
            description: description,
        )

        let playlist = Playlist(from: response)
        store.addPlaylistToUserLibrary(playlist)
        return playlist
    }

    /// Update playlist details (name, description)
    func updatePlaylistDetails(
        playlistId: String,
        name: String? = nil,
        description: String? = nil,
        accessToken: String,
    ) async throws {
        try await SpotifyAPI.updatePlaylistDetails(
            accessToken: accessToken,
            playlistId: playlistId,
            name: name,
            description: description,
        )

        // Update store on success
        store.updatePlaylistDetails(
            id: playlistId,
            name: name,
            description: description,
        )
    }

    /// Delete a playlist
    func deletePlaylist(playlistId: String, accessToken: String) async throws {
        try await SpotifyAPI.deletePlaylist(
            accessToken: accessToken,
            playlistId: playlistId,
        )

        // Remove from store on success
        store.removePlaylistFromUserLibrary(playlistId)
    }

    // MARK: - Track Operations

    /// Add tracks to a playlist
    func addTracksToPlaylist(
        playlistId: String,
        trackIds: [String],
        accessToken: String,
    ) async throws {
        let trackUris = trackIds.map { "spotify:track:\($0)" }

        try await SpotifyAPI.addTracksToPlaylist(
            accessToken: accessToken,
            playlistId: playlistId,
            trackUris: trackUris,
        )

        // Update store on success
        for trackId in trackIds {
            store.addTrackToPlaylist(trackId, playlistId: playlistId)
        }
    }

    /// Remove tracks from a playlist
    func removeTracksFromPlaylist(
        playlistId: String,
        trackIds: [String],
        accessToken: String,
    ) async throws {
        let trackUris = trackIds.map { "spotify:track:\($0)" }

        try await SpotifyAPI.removeTracksFromPlaylist(
            accessToken: accessToken,
            playlistId: playlistId,
            trackUris: trackUris,
        )

        // Update store on success
        for trackId in trackIds {
            store.removeTrackFromPlaylist(trackId, playlistId: playlistId)
        }
    }

    /// Reorder tracks in a playlist
    func reorderPlaylistTracks(
        playlistId: String,
        rangeStart: Int,
        insertBefore: Int,
        rangeLength: Int = 1,
        accessToken: String,
    ) async throws {
        try await SpotifyAPI.reorderPlaylistTracks(
            accessToken: accessToken,
            playlistId: playlistId,
            rangeStart: rangeStart,
            insertBefore: insertBefore,
            rangeLength: rangeLength,
        )

        // Re-fetch playlist to get updated track order
        _ = try await fetchPlaylistDetails(playlistId: playlistId, accessToken: accessToken)
    }

    /// Replace all tracks in a playlist (for bulk edits like reordering/removing)
    func replacePlaylistTracks(
        playlistId: String,
        trackUris: [String],
        accessToken: String,
    ) async throws {
        try await SpotifyAPI.replacePlaylistTracks(
            accessToken: accessToken,
            playlistId: playlistId,
            trackUris: trackUris,
        )

        // Re-fetch to update store with new track order
        _ = try await fetchPlaylistDetails(playlistId: playlistId, accessToken: accessToken)
    }
}
