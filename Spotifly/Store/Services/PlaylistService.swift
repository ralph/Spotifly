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

    init(store: AppStore, tokenProvider: @escaping () async -> String) {
        self.store = store
        self.tokenProvider = tokenProvider
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
            try await self.loadPlaylist(playlistId: playlistId, accessToken: self.tokenProvider())
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
            try await self.loadPlaylist(playlistId: playlistId, accessToken: self.tokenProvider(), forceTracks: true)
        }
    }

    private func loadPlaylist(playlistId: String, accessToken: String, forceTracks: Bool = false) async throws {
        // Re-read inside the run: a caller can arrive just as another run finishes.
        guard let known = store.playlists[playlistId] else {
            async let detailsTask = SpotifyAPI.fetchPlaylistDetails(
                accessToken: accessToken,
                playlistId: playlistId,
            )
            async let tracksTask = SpotifyAPI.fetchPlaylistTracks(
                accessToken: accessToken,
                playlistId: playlistId,
            )
            let (details, playlistTracks) = try await (detailsTask, tracksTask)
            // A reload can supersede this run; it must not write over the fresher order.
            try Task.checkCancellation()

            store.upsertPlaylist(Playlist(from: details))
            storeTracks(playlistTracks, for: playlistId)
            return
        }

        guard forceTracks || !known.tracksLoaded else { return }

        let playlistTracks = try await SpotifyAPI.fetchPlaylistTracks(
            accessToken: accessToken,
            playlistId: playlistId,
        )
        try Task.checkCancellation()
        storeTracks(playlistTracks, for: playlistId)
    }

    /// Stores a playlist's tracks and marks its track list as loaded.
    private func storeTracks(_ playlistTracks: [APITrack], for playlistId: String) {
        let tracks = playlistTracks.map { Track(from: $0) }
        store.upsertTracks(tracks)
        store.setPlaylistTracks(
            tracks.map(\.id),
            totalDurationMs: tracks.reduce(0) { $0 + $1.durationMs },
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

        // Re-fetch to pick up the order the server actually applied
        try await reloadPlaylistTracks(playlistId: playlistId)
    }
}
