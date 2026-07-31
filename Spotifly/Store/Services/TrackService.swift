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

    /// The single metadata fetch path shared by queue hydration and current-track recovery.
    private let metadataFetcher: (_ accessToken: String, _ trackIds: [String]) async throws -> [String: APITrack]

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

    /// Track IDs currently covered by a shared metadata request.
    ///
    /// A request may carry many IDs, while a later caller may overlap only part of that
    /// batch. Mapping each ID to its task lets the caller join the covered work and start
    /// one request for only the remainder. The tasks are unstructured so a disappearing
    /// SwiftUI view cannot cancel work still useful to the queue or its replacement.
    private var metadataLoadsInFlight: [String: (id: UUID, task: Task<Void, Error>)] = [:]

    init(
        store: AppStore,
        tokenProvider: @escaping () async -> String,
        favoriteStatusFetcher: @escaping (_ accessToken: String, _ trackIds: [String]) async throws -> [String: Bool] = { accessToken, trackIds in
            try await SpotifyAPI.checkSavedTracks(accessToken: accessToken, trackIds: trackIds)
        },
        metadataFetcher: @escaping (_ accessToken: String, _ trackIds: [String]) async throws -> [String: APITrack] = { accessToken, trackIds in
            try await SpotifyAPI.fetchTracks(accessToken: accessToken, trackIds: trackIds)
        },
    ) {
        self.store = store
        self.tokenProvider = tokenProvider
        self.favoriteStatusFetcher = favoriteStatusFetcher
        self.metadataFetcher = metadataFetcher
    }

    // MARK: - Track Metadata

    /// Ensures every available track in `trackIds` is present in the normalized store.
    ///
    /// Cache hits return before requesting a token. Overlapping callers join any request
    /// already carrying an ID and fetch only the uncovered remainder. A failed run removes
    /// its entries, so a later call retries normally.
    func ensureTracksLoaded(trackIds: [String]) async throws {
        let missingTrackIds = uniqueTrackIds(trackIds).filter { store.tracks[$0] == nil }
        guard !missingTrackIds.isEmpty else { return }

        var tasks: [(id: UUID, task: Task<Void, Error>)] = []
        var seenTaskIds = Set<UUID>()
        var uncoveredTrackIds: [String] = []

        for trackId in missingTrackIds {
            if let existing = metadataLoadsInFlight[trackId] {
                if seenTaskIds.insert(existing.id).inserted {
                    tasks.append(existing)
                }
            } else {
                uncoveredTrackIds.append(trackId)
            }
        }

        if !uncoveredTrackIds.isEmpty {
            let id = UUID()
            let task = Task { @MainActor in
                defer { self.finishMetadataLoad(id: id, trackIds: uncoveredTrackIds) }

                let accessToken = await self.tokenProvider()
                for batch in self.batches(of: uncoveredTrackIds, size: 50) {
                    let fetched = try await self.metadataFetcher(accessToken, batch)
                    let tracks = batch.compactMap { fetched[$0] }.map { Track(from: $0) }
                    self.store.upsertTracks(tracks)
                }
            }
            let entry = (id, task)
            for trackId in uncoveredTrackIds {
                metadataLoadsInFlight[trackId] = entry
            }
            tasks.append(entry)
        }

        for entry in tasks {
            try await entry.task.value
        }
    }

    private func finishMetadataLoad(id: UUID, trackIds: [String]) {
        for trackId in trackIds where metadataLoadsInFlight[trackId]?.id == id {
            metadataLoadsInFlight[trackId] = nil
        }
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
