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

    /// Used by the loading entry points and the favorite-status checks, which
    /// often decide there is nothing to fetch. They take the token themselves,
    /// *after* deciding, so a cache hit costs nothing.
    private let tokenProvider: () async -> String

    /// Injectable for tests; production uses Spotify's batched contains endpoint.
    private let favoriteStatusFetcher: (_ accessToken: String, _ trackIds: [String]) async throws -> [String: Bool]

    /// The favorites list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "favorites"

    /// Track IDs with a `/me/tracks/contains` check already on its way.
    ///
    /// The resolved-status cache alone does not prevent duplicates: it is only
    /// written when a check *returns*, so two views asking about the same track in
    /// the same frame — a row and the now-playing bar, say — both see it unresolved
    /// and both ask. Keeping the task, rather than just a busy marker, also lets the
    /// second caller await the result. The task is unstructured, so cancellation of
    /// the SwiftUI task that started it does not strand the replacement view.
    ///
    /// This is deliberately not `InFlightRequests`, even though it wants the same two
    /// guarantees. That registry maps one key to one run; a `contains` request covers
    /// *many* tracks, and the next caller arrives with an overlapping but different
    /// set — it has to join the runs already carrying some of its tracks and start one
    /// for the rest. Folding the two together would mean teaching the registry a
    /// many-to-one key relation it does not have, to save a dictionary and a `defer`.
    private var checksInFlight: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        store: AppStore,
        tokenProvider: @escaping () async -> String,
        favoriteStatusFetcher: @escaping (_ accessToken: String, _ trackIds: [String]) async throws -> [String: Bool] = { accessToken, trackIds in
            try await SpotifyAPI.checkSavedTracks(accessToken: accessToken, trackIds: trackIds)
        },
    ) {
        self.store = store
        self.tokenProvider = tokenProvider
        self.favoriteStatusFetcher = favoriteStatusFetcher
    }

    // MARK: - Favorites (Saved Tracks)

    /// Load the next page of the user's saved tracks, or the first if none is loaded.
    func loadFavorites(forceRefresh: Bool = false) async throws {
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
            let accessToken = await self.tokenProvider()
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
    func loadMoreFavorites() async throws {
        guard store.favoritesPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
            return
        }
        try await loadFavorites()
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

    /// The one request the checks below are built out of. Private so every caller
    /// goes through `ensureFavoriteStatuses`/`refreshFavoriteStatuses` and is
    /// deduplicated against `checksInFlight`.
    private func checkFavoriteStatuses(trackIds: [String], accessToken: String) async throws {
        guard !trackIds.isEmpty else { return }

        let statuses = try await favoriteStatusFetcher(accessToken, trackIds)

        store.updateFavoriteStatuses(statuses)
    }

    /// Resolve favorite status for any tracks we haven't checked yet.
    /// Callers should batch track IDs (e.g. all tracks in a list) for efficiency.
    func ensureFavoriteStatuses(trackIds: [String]) async {
        let unresolved = uniqueTrackIds(trackIds).filter {
            !store.hasResolvedFavoriteStatus(for: $0)
        }
        await check(unresolved)
    }

    /// Refresh favorite status for the given tracks even if we have stale cached data.
    func refreshFavoriteStatuses(trackIds: [String]) async {
        // Deliberately ignores the resolved cache — that is the point of a refresh.
        // `check` still joins any request already carrying the same track.
        await check(uniqueTrackIds(trackIds))
    }

    private func check(_ trackIds: [String]) async {
        guard !trackIds.isEmpty else { return }

        var tasks: [(id: UUID, task: Task<Void, Never>)] = []
        var seenTaskIds = Set<UUID>()
        var uncheckedTrackIds: [String] = []

        for trackId in trackIds {
            if let existing = checksInFlight[trackId] {
                if seenTaskIds.insert(existing.id).inserted {
                    tasks.append(existing)
                }
            } else {
                uncheckedTrackIds.append(trackId)
            }
        }

        if !uncheckedTrackIds.isEmpty {
            let id = UUID()
            let task = Task { @MainActor in
                defer { self.finishFavoriteCheck(id: id, trackIds: uncheckedTrackIds) }

                let accessToken = await self.tokenProvider()
                for batch in self.batches(of: uncheckedTrackIds, size: 50) {
                    try? await self.checkFavoriteStatuses(trackIds: batch, accessToken: accessToken)
                }
            }
            let entry = (id, task)
            for trackId in uncheckedTrackIds {
                checksInFlight[trackId] = entry
            }
            tasks.append(entry)
        }

        for entry in tasks {
            await entry.task.value
        }
    }

    private func finishFavoriteCheck(id: UUID, trackIds: [String]) {
        for trackId in trackIds where checksInFlight[trackId]?.id == id {
            checksInFlight[trackId] = nil
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
