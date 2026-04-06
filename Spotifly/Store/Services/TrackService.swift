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
        store.markTracksAsFavorite(trackIds)

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

    /// Resolve favorite status for any tracks we haven't checked yet.
    /// Callers should batch track IDs (e.g. all tracks in a list) for efficiency.
    func ensureFavoriteStatuses(trackIds: [String], accessToken: String) async {
        let unresolved = uniqueTrackIds(trackIds).filter { !store.hasResolvedFavoriteStatus(for: $0) }
        guard !unresolved.isEmpty else { return }

        for batch in batches(of: unresolved, size: 50) {
            try? await checkFavoriteStatuses(trackIds: batch, accessToken: accessToken)
        }
    }

    /// Refresh favorite status for the given tracks even if we have stale cached data.
    func refreshFavoriteStatuses(trackIds: [String], accessToken: String) async {
        let uniqueIds = uniqueTrackIds(trackIds)
        guard !uniqueIds.isEmpty else { return }

        for batch in batches(of: uniqueIds, size: 50) {
            try? await checkFavoriteStatuses(trackIds: batch, accessToken: accessToken)
        }
    }

    // MARK: - Track Lookup

    /// Fetch and store a single track by ID
    func fetchTrack(trackId: String, accessToken: String) async throws -> Track {
        let apiTrack = try await SpotifyAPI.fetchTrack(
            trackId: trackId,
            accessToken: accessToken,
        )

        let track = Track(from: apiTrack)
        store.upsertTrack(track)
        return track
    }

    private func uniqueTrackIds(_ trackIds: [String]) -> [String] {
        var seen = Set<String>()
        return trackIds.filter { seen.insert($0).inserted }
    }

    private func batches(of trackIds: [String], size: Int) -> [[String]] {
        stride(from: 0, to: trackIds.count, by: size).map {
            Array(trackIds[$0 ..< min($0 + size, trackIds.count)])
        }
    }
}
