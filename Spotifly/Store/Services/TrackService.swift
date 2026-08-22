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

    /// The favorites reads and writes, which take no token: `PartnerAPI` runs on the keymaster
    /// grant and holds it itself.
    private let partnerAPI: PartnerAPI

    /// Injectable for tests; production asks pathfinder which of a batch are in the library.
    private let favoriteStatusFetcher: (_ trackIds: [String]) async throws -> [String: Bool]

    /// The single metadata fetch path shared by queue hydration and current-track recovery.
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
        partnerAPI: PartnerAPI = PartnerAPI(),
        favoriteStatusFetcher: ((_ trackIds: [String]) async throws -> [String: Bool])? = nil,
        metadataFetcher: @escaping (_ trackIds: [String]) async throws -> [String: Track] = { trackIds in
            try await SpclientAPI().trackEntities(ids: trackIds)
        },
    ) {
        self.store = store
        self.partnerAPI = partnerAPI
        self.favoriteStatusFetcher = favoriteStatusFetcher ?? { trackIds in
            try await partnerAPI.entitiesInLibrary(uris: trackIds.map { "spotify:track:\($0)" })
        }
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
        let missingTrackIds = trackIds.uniqued().filter {
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
            try await self.store.loadLibraryPage(\.favoritesPagination) { offset in
                let page = try await self.partnerAPI.libraryTracks(offset: offset, limit: 50)
                // See AlbumService.loadUserAlbums: a superseded run must not write.
                try Task.checkCancellation()

                let tracks = page.tracks
                self.store.upsertTracks(tracks)

                let trackIds = tracks.map(\.id)
                if offset == 0 {
                    self.store.setSavedTrackIds(trackIds)
                } else {
                    self.store.appendSavedTrackIds(trackIds)
                }
                self.store.markTracksAsFavorite(trackIds)

                return (page.items?.count ?? 0, page.totalCount ?? 0)
            }
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

    /// Toggle favorite status for a track (optimistic update).
    ///
    /// The write goes out with the id the store holds, which is the **market** id — the one
    /// pathfinder returned. Spotify's docs warn that a relinked substitute "will likely return
    /// an error" for saves; measured on 2026-08-13, it does not, and the collection service
    /// echoes the change back under that same id. See `AGENTS.md`.
    func toggleFavorite(trackId: String) async throws {
        let wasOriginallyFavorite = store.isFavorite(trackId)

        // Optimistic update - immediately update UI
        if wasOriginallyFavorite {
            store.removeTrackFromFavorites(trackId)
        } else {
            store.addTrackToFavorites(trackId)
        }

        let uris = ["spotify:track:\(trackId)"]

        do {
            // Make API call
            if wasOriginallyFavorite {
                try await partnerAPI.removeFromLibrary(uris: uris)
            } else {
                try await partnerAPI.addToLibrary(uris: uris)
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

    /// How many track ids one `entitiesInLibrary` request may carry.
    private static let statusBatchSize = 50

    /// Resolve favorite status for any tracks we haven't checked yet.
    /// Callers should batch track IDs (e.g. all tracks in a list) for efficiency.
    ///
    /// There was a `refreshFavoriteStatuses` beside this that skipped the resolved cache, for
    /// callers wanting to re-ask. Its only caller was the Now Playing bar, firing on every view
    /// re-appearance — seven identical requests for one track in under two minutes — so it was
    /// removed with that call rather than left as a loaded gun. A genuine need to re-ask should
    /// come from Spotify's collection change feed rather than from polling.
    func ensureFavoriteStatuses(trackIds: [String]) async {
        let unresolved = trackIds.uniqued().filter {
            !store.hasResolvedFavoriteStatus(for: $0)
        }
        guard !unresolved.isEmpty else { return }

        // A failed check is not worth reporting — the heart just stays as it was — so
        // the run swallows its own errors and `run` has nothing left to throw.
        try? await statusChecks.run(unresolved) { uncheckedTrackIds in
            for batch in Self.statusBatches(of: uncheckedTrackIds) {
                guard let statuses = try? await self.favoriteStatusFetcher(batch) else { continue }
                self.store.updateFavoriteStatuses(statuses)
            }
        }
    }

    private static func statusBatches(of trackIds: [String]) -> [[String]] {
        stride(from: 0, to: trackIds.count, by: statusBatchSize).map {
            Array(trackIds[$0 ..< min($0 + statusBatchSize, trackIds.count)])
        }
    }
}
