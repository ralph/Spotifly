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

    /// Used by the loading entry points, which often decide there is nothing to
    /// fetch. They take the token themselves, *after* deciding, so a cache hit
    /// costs nothing.
    private let tokenProvider: () async -> String

    /// One run per playlist ID — see `InFlightRequests`.
    private let playlistRequests = InFlightRequests<Void>()

    /// The user's playlist list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-playlists"

    /// The playlist reads and the item mutations, which take no token: `PartnerAPI` runs on
    /// the keymaster grant and holds it itself. `tokenProvider` is the Web API's, still needed
    /// by the playlist list and the create/rename/delete/follow writes.
    private let partnerAPI: PartnerAPI

    init(
        store: AppStore,
        tokenProvider: @escaping () async -> String,
        partnerAPI: PartnerAPI = PartnerAPI(),
    ) {
        self.store = store
        self.tokenProvider = tokenProvider
        self.partnerAPI = partnerAPI
    }

    // MARK: - User Playlists

    /// Load the next page of the user's playlists, or the first if none is loaded.
    func loadUserPlaylists(forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.playlistsPagination.isLoaded, !forceRefresh, !store.playlistsPagination.hasMore, !store.userPlaylistIds.isEmpty {
            return
        }

        if forceRefresh {
            listRequests.cancel(Self.listKey)
            store.playlistsPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            let offset = self.store.playlistsPagination.nextOffset ?? 0
            let accessToken = await self.tokenProvider()
            self.store.playlistsPagination.isLoading = true
            defer {
                // Only if this run is still the one loading: a superseded run
                // must not clear the state its replacement just set.
                if !Task.isCancelled {
                    self.store.playlistsPagination.isLoading = false
                }
            }

            let response = try await SpotifyAPI.fetchUserPlaylists(
                accessToken: accessToken,
                limit: 50,
                offset: offset,
            )
            // See AlbumService.loadUserAlbums: a superseded run must not write.
            try Task.checkCancellation()

            let playlists = response.playlists.map { Playlist(from: $0) }
            self.store.upsertPlaylists(playlists)

            let playlistIds = playlists.map(\.id)
            if offset == 0 {
                self.store.setUserPlaylistIds(playlistIds)
            } else {
                self.store.appendUserPlaylistIds(playlistIds)
            }

            self.store.playlistsPagination.isLoaded = true
            self.store.playlistsPagination.hasMore = response.hasMore
            self.store.playlistsPagination.nextOffset = response.nextOffset
            self.store.playlistsPagination.total = response.total
        }
    }

    /// Load more playlists (pagination)
    func loadMorePlaylists() async throws {
        guard store.playlistsPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
            return
        }
        try await loadUserPlaylists()
    }

    // MARK: - Playlist Details

    /// Makes sure the playlist's metadata *and* its track list are in the store.
    ///
    /// Only what is missing goes over the network: a playlist that came from the
    /// library list or a search result already has its metadata, so just its tracks
    /// are fetched; on a second visit nothing is. Concurrent callers share one run,
    /// and the run outlives a caller whose view was torn down mid-flight — see
    /// `InFlightRequests`.
    func ensurePlaylistLoaded(playlistId: String) async throws {
        guard store.playlists[playlistId]?.tracksLoaded != true else { return }

        try await playlistRequests.run(playlistId) {
            try await self.loadPlaylist(playlistId: playlistId)
        }
    }

    /// Re-fetches a playlist's track list, ignoring the cached copy.
    ///
    /// Reordering needs exactly this: it updates the store optimistically, so the
    /// cache holds the very order a rollback has to undo. Only the tracks are
    /// re-fetched — a reorder cannot change a playlist's metadata, so making the
    /// rollback depend on a second request that can fail on its own would only give
    /// it another way to leave the wrong order in place.
    ///
    /// It shares `ensurePlaylistLoaded`'s key, and therefore has to keep its
    /// postcondition — a caller can join either one. So a playlist that is somehow
    /// not in the store still gets loaded whole here; this only *adds* the guarantee
    /// that the tracks are freshly fetched.
    func reloadPlaylistTracks(playlistId: String) async throws {
        playlistRequests.cancel(playlistId)

        try await playlistRequests.run(playlistId) {
            try await self.loadPlaylist(playlistId: playlistId, forceTracks: true)
        }
    }

    /// Loads a playlist and its contents in **one** request.
    ///
    /// `fetchPlaylist` answers with both, so the two-branch shape this replaces — details
    /// cached, tracks not — has nothing left to skip.
    private func loadPlaylist(playlistId: String, forceTracks: Bool = false) async throws {
        if !forceTracks, let known = store.playlists[playlistId], known.tracksLoaded {
            return
        }

        let union = try await partnerAPI.playlist(id: playlistId)
        // A reload can supersede this run; it must not write over the fresher order.
        try Task.checkCancellation()

        guard let (playlist, tracks) = union.entities() else {
            throw PartnerAPIError.emptyPayload
        }

        store.upsertPlaylist(playlist)
        store.upsertTracks(tracks)
        store.setPlaylistTracks(
            playlist.items,
            totalDurationMs: playlist.totalDurationMs,
            for: playlistId,
        )
    }

    // MARK: - Playlist Mutations

    /// Create a new playlist
    func createPlaylist(
        name: String,
        description: String? = nil,
        accessToken: String,
    ) async throws -> Playlist {
        let response = try await SpotifyAPI.createPlaylist(
            accessToken: accessToken,
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

    /// Follow (save) a playlist to the user's library
    func followPlaylist(playlistId: String, accessToken: String) async throws {
        try await SpotifyAPI.followPlaylist(
            accessToken: accessToken,
            playlistId: playlistId,
        )

        // Update store on success
        store.addPlaylistToUserLibraryById(playlistId)
    }

    // MARK: - Track Operations

    /// Add tracks to a playlist
    func addTracksToPlaylist(
        playlistId: String,
        trackIds: [String],
    ) async throws {
        try await partnerAPI.addToPlaylist(
            playlistId: playlistId,
            trackUris: trackIds.map { "spotify:track:\($0)" },
        )

        // Optimistically, then reload. The mutation does not return the uids Spotify assigned,
        // and a row without its real uid cannot be removed or reordered — so the placeholder
        // rows exist only long enough for the refresh to replace them.
        for trackId in trackIds {
            store.addTrackToPlaylist(trackId, playlistId: playlistId)
        }
        try await reloadPlaylistTracks(playlistId: playlistId)
    }

    /// Remove a track from a playlist, resolving it to the **first** occurrence.
    ///
    /// For callers holding a `Track` and no uid — the context menu, which is shared by every
    /// list in the app and does not know which row it was opened from. Removing the first
    /// occurrence is already an improvement on the Web API path, which removed *every* copy of
    /// a track; making it exact needs the uid threaded through `TrackRow`, and that is worth
    /// doing when a view other than the playlist page can produce duplicates.
    func removeTracksFromPlaylist(
        playlistId: String,
        trackIds: [String],
    ) async throws {
        let uids = trackIds.compactMap { trackId in
            store.playlists[playlistId]?.items.first { $0.trackId == trackId }?.uid
        }
        guard !uids.isEmpty else { return }

        try await removePlaylistItems(playlistId: playlistId, uids: uids)
    }

    /// Remove **occurrences** from a playlist, named by uid.
    ///
    /// Not by track id: a playlist can hold the same song more than once, and the Web API path
    /// this replaces removed every copy of it. A uid names the row the user actually chose.
    func removePlaylistItems(
        playlistId: String,
        uids: [String],
    ) async throws {
        try await partnerAPI.removeFromPlaylist(playlistId: playlistId, uids: uids)

        for uid in uids {
            store.removePlaylistItem(uid: uid, playlistId: playlistId)
        }
    }

    /// Move one item to sit before another, both named by uid.
    func movePlaylistItem(
        playlistId: String,
        uid: String,
        beforeUid: String?,
    ) async throws {
        // No `beforeUid` means the end of the list, which the enum spells as its own move type
        // rather than as a position.
        let position = beforeUid.map(PlaylistItemPosition.before(uid:)) ?? .bottom

        try await partnerAPI.moveInPlaylist(
            playlistId: playlistId,
            uids: [uid],
            position: position,
        )

        // Re-fetch to pick up the order the server actually applied
        try await reloadPlaylistTracks(playlistId: playlistId)
    }
}
