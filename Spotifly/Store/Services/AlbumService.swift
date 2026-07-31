//
//  AlbumService.swift
//  Spotifly
//
//  Service for album-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class AlbumService {
    private let store: AppStore

    /// One run per album ID — see `InFlightRequests`.
    private let albumRequests = InFlightRequests<Void>()

    /// The saved-albums list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-albums"

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - User Albums

    /// Load the next page of the user's saved albums, or the first if none is loaded.
    func loadUserAlbums(accessToken: String, forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.albumsPagination.isLoaded, !forceRefresh, !store.albumsPagination.hasMore, !store.userAlbumIds.isEmpty {
            return
        }

        if forceRefresh {
            listRequests.cancel(Self.listKey)
            store.albumsPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            let offset = self.store.albumsPagination.nextOffset ?? 0
            self.store.albumsPagination.isLoading = true
            defer { self.store.albumsPagination.isLoading = false }

            let response = try await SpotifyAPI.fetchUserAlbums(
                accessToken: accessToken,
                limit: 20,
                offset: offset,
            )
            // A force refresh cancels this run and starts another. Cancellation is
            // cooperative, so without this the superseded page would still be
            // written — over the reset its replacement just performed.
            try Task.checkCancellation()

            let albums = response.albums.map { Album(from: $0) }
            self.store.upsertAlbums(albums)

            let albumIds = albums.map(\.id)
            if offset == 0 {
                self.store.setUserAlbumIds(albumIds)
            } else {
                self.store.appendUserAlbumIds(albumIds)
            }

            self.store.albumsPagination.isLoaded = true
            self.store.albumsPagination.hasMore = response.hasMore
            self.store.albumsPagination.nextOffset = response.nextOffset
            self.store.albumsPagination.total = response.total
        }
    }

    /// Load more albums (pagination)
    func loadMoreAlbums(accessToken: String) async throws {
        guard store.albumsPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
            return
        }
        try await loadUserAlbums(accessToken: accessToken)
    }

    // MARK: - Album Details

    /// Makes sure the album's metadata *and* its track list are in the store.
    ///
    /// Only what is missing goes over the network. An album opened from the library
    /// list, an artist page or a search result already has its metadata, so just
    /// `/albums/{id}/tracks` is fetched; on a second visit nothing is. Concurrent
    /// callers share one run, and the run outlives a caller whose view was torn
    /// down mid-flight — see `InFlightRequests`.
    func ensureAlbumLoaded(albumId: String, accessToken: String) async throws {
        guard needsLoad(albumId) else { return }

        try await albumRequests.run(albumId) {
            try await self.loadAlbum(albumId: albumId, accessToken: accessToken)
        }
    }

    private func needsLoad(_ albumId: String) -> Bool {
        guard let album = store.albums[albumId] else { return true }
        return !album.detailsLoaded || !album.tracksLoaded
    }

    private func loadAlbum(albumId: String, accessToken: String) async throws {
        // Re-checked inside the run: a caller can arrive just as another run finishes.
        guard let known = store.albums[albumId], known.detailsLoaded else {
            // Nothing usable in the store — metadata and tracks both have to come down.
            async let detailsTask = SpotifyAPI.fetchAlbumDetails(
                accessToken: accessToken,
                albumId: albumId,
            )
            async let tracksTask = SpotifyAPI.fetchAlbumTracks(
                accessToken: accessToken,
                albumId: albumId,
            )
            let (details, albumTracks) = try await (detailsTask, tracksTask)

            let album = Album(from: details)
            store.upsertAlbum(album)
            storeTracks(albumTracks, for: album)
            return
        }

        guard !known.tracksLoaded else { return }

        let albumTracks = try await SpotifyAPI.fetchAlbumTracks(
            accessToken: accessToken,
            albumId: albumId,
        )
        storeTracks(albumTracks, for: known)
    }

    /// Stores an album's tracks and marks the album's track list as loaded.
    /// The album tracks endpoint omits album context, so it is filled in here.
    private func storeTracks(_ albumTracks: [APITrack], for album: Album) {
        let tracks = albumTracks.map { albumTrack in
            Track(
                from: albumTrack,
                albumId: album.id,
                albumName: album.name,
                images: album.images,
            )
        }
        store.upsertTracks(tracks)
        store.setAlbumTracks(
            tracks.map(\.id),
            totalDurationMs: tracks.reduce(0) { $0 + $1.durationMs },
            for: album.id,
        )
    }

    // MARK: - Library Management

    /// Save an album to the user's library
    func saveAlbumToLibrary(albumId: String, accessToken: String) async throws {
        try await SpotifyAPI.saveUserAlbum(
            accessToken: accessToken,
            albumId: albumId,
        )

        // Update store on success
        store.addAlbumToUserLibrary(albumId)
    }

    /// Remove an album from the user's library
    func removeAlbumFromLibrary(albumId: String, accessToken: String) async throws {
        try await SpotifyAPI.removeUserAlbum(
            accessToken: accessToken,
            albumId: albumId,
        )

        // Update store on success
        store.removeAlbumFromUserLibrary(albumId)
    }
}
