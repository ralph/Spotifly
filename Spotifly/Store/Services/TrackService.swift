//
//  TrackService.swift
//  Spotifly
//
//  Service for track-related operations including favorites.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class TrackService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Favorites (Saved Tracks)

    /// Load user's saved tracks (favorites)
    func loadFavorites(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh
        if store.favoritesPagination.isLoaded, !forceRefresh, !store.favoritesPagination.hasMore {
            return
        }

        // Reset pagination on force refresh
        if forceRefresh {
            store.favoritesPagination.reset()
        }

        guard !store.favoritesPagination.isLoading else { return }
        store.favoritesPagination.isLoading = true

        defer { store.favoritesPagination.isLoading = false }

        let offset = forceRefresh ? 0 : (store.favoritesPagination.nextOffset ?? 0)

        let response = try await SpotifyAPI.fetchUserSavedTracks(
            accessToken: accessToken,
            limit: 50,
            offset: offset,
        )

        // Convert to unified Track entities
        let tracks = response.tracks.map { Track(from: $0) }

        // Upsert tracks into store
        store.upsertTracks(tracks)

        // Update saved track IDs
        let trackIds = tracks.map(\.id)
        if forceRefresh {
            store.setSavedTrackIds(trackIds)
        } else {
            store.appendSavedTrackIds(trackIds)
        }

        // Update pagination state
        store.favoritesPagination.isLoaded = true
        store.favoritesPagination.hasMore = response.hasMore
        store.favoritesPagination.nextOffset = response.nextOffset
        store.favoritesPagination.total = response.total
    }

    /// Load more favorites (pagination)
    func loadMoreFavorites(accessToken: String) async throws {
        guard store.favoritesPagination.hasMore, !store.favoritesPagination.isLoading else {
            return
        }
        try await loadFavorites(accessToken: accessToken)
    }

    // MARK: - Favorite Toggling (Optimistic)

    /// Toggle favorite status for a track (optimistic update)
    func toggleFavorite(trackId: String, accessToken: String) async throws {
        let wasOriginallyFavorite = store.isFavorite(trackId)

        // Optimistic update - immediately update UI
        if wasOriginallyFavorite {
            store.removeTrackFromFavorites(trackId)
        } else {
            store.addTrackToFavorites(trackId)
        }

        do {
            // Make API call
            if wasOriginallyFavorite {
                try await SpotifyAPI.removeSavedTrack(accessToken: accessToken, trackId: trackId)
            } else {
                try await SpotifyAPI.saveTrack(accessToken: accessToken, trackId: trackId)
            }
        } catch {
            // Rollback on failure
            if wasOriginallyFavorite {
                store.addTrackToFavorites(trackId)
            } else {
                store.removeTrackFromFavorites(trackId)
            }
            throw error
        }
    }

    /// Toggle favorite for currently playing track
    func toggleCurrentTrackFavorite(accessToken: String) async throws {
        guard let trackId = extractTrackId(from: store.currentTrackId) else {
            return
        }
        try await toggleFavorite(trackId: trackId, accessToken: accessToken)
    }

    // MARK: - Favorite Status Check

    /// Check favorite status for a single track
    func checkFavoriteStatus(trackId: String, accessToken: String) async throws {
        let isFavorite = try await SpotifyAPI.checkSavedTrack(
            accessToken: accessToken,
            trackId: trackId,
        )

        store.updateFavoriteStatuses([trackId: isFavorite])
    }

    /// Check favorite status for multiple tracks
    func checkFavoriteStatuses(trackIds: [String], accessToken: String) async throws {
        guard !trackIds.isEmpty else { return }

        let statuses = try await SpotifyAPI.checkSavedTracks(
            accessToken: accessToken,
            trackIds: trackIds,
        )

        store.updateFavoriteStatuses(statuses)
    }

    /// Check favorite status for current track
    func checkCurrentTrackFavoriteStatus(accessToken: String) async throws {
        guard let trackId = extractTrackId(from: store.currentTrackId) else {
            return
        }
        try await checkFavoriteStatus(trackId: trackId, accessToken: accessToken)
    }

    // MARK: - Track Lookup

    /// Fetch and store a single track by ID
    func fetchTrack(trackId: String, accessToken: String) async throws -> Track {
        let metadata = try await SpotifyAPI.fetchTrackMetadata(
            trackId: trackId,
            accessToken: accessToken,
        )

        let track = Track(from: metadata)
        store.upsertTrack(track)
        return track
    }

    // MARK: - Helpers

    private func extractTrackId(from uri: String?) -> String? {
        guard let uri else { return nil }
        let components = uri.split(separator: ":")
        guard components.count >= 3, components[0] == "spotify", components[1] == "track" else {
            return nil
        }
        return String(components[2])
    }
}
