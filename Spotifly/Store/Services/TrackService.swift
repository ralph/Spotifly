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

    /// Used by the favorite-status checks, which usually have nothing to ask about.
    /// They take the token themselves, *after* deciding, so that a track row whose
    /// status is already known — or already being fetched — costs nothing at all.
    private let tokenProvider: () async -> String

    /// The favorites list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "favorites"

    /// Track IDs with a `/me/tracks/contains` check already on its way.
    ///
    /// The resolved-status cache alone does not prevent duplicates: it is only
    /// written when a check *returns*, so two views asking about the same track in
    /// the same frame — a row and the now-playing bar, say — both see it unresolved
    /// and both ask.
    private var checksInFlight: Set<String> = []

    init(store: AppStore, tokenProvider: @escaping () async -> String) {
        self.store = store
        self.tokenProvider = tokenProvider
    }

    // MARK: - Favorites (Saved Tracks)

    /// Load the next page of the user's saved tracks, or the first if none is loaded.
    func loadFavorites(accessToken: String, forceRefresh: Bool = false) async throws {
        // The list can be reported as loaded while holding nothing — a page whose
        // load was interrupted. Recover by starting over rather than by trusting it.
        let needsRecoveryRefresh = !forceRefresh &&
            store.favoriteTracks.isEmpty &&
            store.favoritesPagination.isLoaded &&
            store.favoritesPagination.total > 0
        let shouldForceRefresh = forceRefresh || needsRecoveryRefresh

        // Skip if already loaded and not forcing refresh
        if store.favoritesPagination.isLoaded, !shouldForceRefresh, !store.favoritesPagination.hasMore {
            return
        }

        if shouldForceRefresh {
            listRequests.cancel(Self.listKey)
            store.favoritesPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            let offset = self.store.favoritesPagination.nextOffset ?? 0
            self.store.favoritesPagination.isLoading = true
            defer {
                // Only if this run is still the one loading: a superseded run
                // must not clear the state its replacement just set.
                if !Task.isCancelled {
                    self.store.favoritesPagination.isLoading = false
                }
            }

            let response = try await SpotifyAPI.fetchUserSavedTracks(
                accessToken: accessToken,
                limit: 50,
                offset: offset,
            )
            // See AlbumService.loadUserAlbums: a superseded run must not write.
            try Task.checkCancellation()

            let tracks = response.tracks.map { Track(from: $0) }
            self.store.upsertTracks(tracks)

            let trackIds = tracks.map(\.id)
            if offset == 0 {
                self.store.setSavedTrackIds(trackIds)
            } else {
                self.store.appendSavedTrackIds(trackIds)
            }
            self.store.markTracksAsFavorite(trackIds)

            self.store.favoritesPagination.isLoaded = true
            self.store.favoritesPagination.hasMore = response.hasMore
            self.store.favoritesPagination.nextOffset = response.nextOffset
            self.store.favoritesPagination.total = response.total
        }
    }

    /// Load more favorites (pagination)
    func loadMoreFavorites(accessToken: String) async throws {
        guard store.favoritesPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
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
    func ensureFavoriteStatuses(trackIds: [String]) async {
        let unresolved = uniqueTrackIds(trackIds).filter {
            !store.hasResolvedFavoriteStatus(for: $0) && !checksInFlight.contains($0)
        }
        await check(unresolved)
    }

    /// Refresh favorite status for the given tracks even if we have stale cached data.
    func refreshFavoriteStatuses(trackIds: [String]) async {
        // Deliberately ignores the resolved cache — that is the point of a refresh —
        // but not the in-flight set: a check already on its way carries the same
        // answer this one would ask for.
        let stale = uniqueTrackIds(trackIds).filter { !checksInFlight.contains($0) }
        await check(stale)
    }

    private func check(_ trackIds: [String]) async {
        guard !trackIds.isEmpty else { return }

        checksInFlight.formUnion(trackIds)
        defer { checksInFlight.subtract(trackIds) }

        let accessToken = await tokenProvider()
        for batch in batches(of: trackIds, size: 50) {
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
