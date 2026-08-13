//
//  TrackService.swift
//  Spotifly
//
//  Shared service for track metadata and favorite operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class TrackService {
    private let store: AppStore

    /// The **Web API** token, used by the favorites paths — the only ones still on
    /// `api.spotify.com`. They often decide there is nothing to fetch, so they take the token
    /// themselves, *after* deciding, and a cache hit costs nothing.
    private let tokenProvider: () async -> String

    /// Injectable for tests; production uses Spotify's batched contains endpoint.
    private let favoriteStatusFetcher: (_ accessToken: String, _ trackIds: [String]) async throws -> [String: Bool]

    /// The single metadata fetch path shared by queue hydration and current-track recovery.
    ///
    /// Takes no token, unlike the favorites fetcher beside it: this one reads spclient on the
    /// keymaster grant, which `SpclientAPI` holds itself, and the token `tokenProvider` returns
    /// is the Web API's. The two are not interchangeable — a keymaster token gets 429 from
    /// `api.spotify.com` — so they must not meet in one parameter.
    private let metadataFetcher: (_ trackIds: [String]) async throws -> [String: Track]

    /// The favorites list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "favorites"

    /// `/me/tracks/contains` checks, deduplicated per track ID.
    private let statusChecks = BatchInFlightRequests()

    /// spclient metadata loads, deduplicated per track ID. Worth more than it was: one call
    /// here is now one request *per track*, so a joined run saves a request rather than a slot
    /// in someone else's batch.
    private let metadataLoads = BatchInFlightRequests()

    /// Track IDs a *successful* request came back without.
    ///
    /// The store can only cache what Spotify returned, so an ID that does not resolve for
    /// this user's market stays absent and passes the missing-from-store filter forever.
    /// A playlist holding a few such tracks would otherwise pay for them again on every
    /// queue update. Only a response that arrived marks an ID here — a thrown request
    /// leaves it eligible, so a network failure still retries.
    private var unavailableTrackIds: Set<String> = []

    init(
        store: AppStore,
        tokenProvider: @escaping () async -> String,
        favoriteStatusFetcher: @escaping (_ accessToken: String, _ trackIds: [String]) async throws -> [String: Bool] = { accessToken, trackIds in
            try await SpotifyAPI.checkSavedTracks(accessToken: accessToken, trackIds: trackIds)
        },
        metadataFetcher: @escaping (_ trackIds: [String]) async throws -> [String: Track] = { trackIds in
            try await SpclientAPI().trackEntities(ids: trackIds)
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
    /// Cache hits return before anything is fetched. Overlapping callers join any request
    /// already carrying an ID and fetch only the uncovered remainder. A failed run removes
    /// its entries, so a later call retries normally, while an ID Spotify answered without
    /// is not asked for again — which is why `SpclientAPI.tracks` is careful to report only a
    /// genuine 404 as an absence, and to throw on anything that might not recur.
    func ensureTracksLoaded(trackIds: [String]) async throws {
        let missingTrackIds = uniqueTrackIds(trackIds).filter {
            store.tracks[$0] == nil && !unavailableTrackIds.contains($0)
        }
        guard !missingTrackIds.isEmpty else { return }

        try await metadataLoads.run(missingTrackIds) { uncoveredTrackIds in
            let fetched = try await self.metadataFetcher(uncoveredTrackIds)
            self.store.upsertTracks(uncoveredTrackIds.compactMap { fetched[$0] })
            self.unavailableTrackIds.formUnion(uncoveredTrackIds.filter { fetched[$0] == nil })
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

    /// The one request the checks below are built out of. Private so every caller goes
    /// through `ensureFavoriteStatuses` and is deduplicated against `checksInFlight`.
    ///
    /// There was a `refreshFavoriteStatuses` beside it that skipped the resolved cache, for
    /// callers wanting to re-ask. Its only caller was the Now Playing bar, firing on every view
    /// re-appearance — seven identical requests for one track in under two minutes — so it was
    /// removed with that call rather than left as a loaded gun. A genuine need to re-ask should
    /// come from Spotify's collection change feed rather than from polling.
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

    private func check(_ trackIds: [String]) async {
        guard !trackIds.isEmpty else { return }

        // A failed check is not worth reporting — the heart just stays as it was — so
        // the run swallows its own errors and `run` has nothing left to throw.
        try? await statusChecks.run(trackIds) { uncheckedTrackIds in
            let accessToken = await self.tokenProvider()
            for batch in self.batches(of: uncheckedTrackIds, size: 50) {
                try? await self.checkFavoriteStatuses(trackIds: batch, accessToken: accessToken)
            }
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
