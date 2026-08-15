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

    /// Every album path now runs on the keymaster grant, which `PartnerAPI` holds itself — so
    /// this service no longer takes a Web API token at all. Injectable so tests can drive it
    /// without a network.
    private let partnerAPI: PartnerAPI

    /// One run per album ID — see `InFlightRequests`.
    private let albumRequests = InFlightRequests<Void>()

    /// The saved-albums list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-albums"

    init(
        store: AppStore,
        partnerAPI: PartnerAPI = PartnerAPI(),
    ) {
        self.store = store
        self.partnerAPI = partnerAPI
    }

    // MARK: - User Albums

    /// Load the next page of the user's saved albums, or the first if none is loaded.
    func loadUserAlbums(forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.albumsPagination.isLoaded, !forceRefresh, !store.albumsPagination.hasMore, !store.userAlbumIds.isEmpty {
            return
        }

        if forceRefresh {
            listRequests.cancel(Self.listKey)
            store.albumsPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            try await self.store.loadLibraryPage(\.albumsPagination) { offset in
                let page = try await self.partnerAPI.libraryAlbums(offset: offset)
                // A force refresh cancels this run and starts another. Cancellation is
                // cooperative, so without this the superseded page would still be
                // written — over the reset its replacement just performed.
                try Task.checkCancellation()

                let albums = page.entities.compactMap { Album(pathfinder: $0) }
                self.store.upsertAlbums(albums)

                let albumIds = albums.map(\.id)
                if offset == 0 {
                    self.store.setUserAlbumIds(albumIds)
                } else {
                    self.store.appendUserAlbumIds(albumIds)
                }

                return (page.items?.count ?? 0, page.totalCount ?? 0)
            }
        }
    }

    /// Load more albums (pagination)
    func loadMoreAlbums() async throws {
        guard store.albumsPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
            return
        }
        try await loadUserAlbums()
    }

    // MARK: - Album Details

    /// Makes sure the album's metadata *and* its track list are in the store.
    ///
    /// Only what is missing goes over the network. An album opened from the library
    /// list, an artist page or a search result already has its metadata, so just
    /// `/albums/{id}/tracks` is fetched; on a second visit nothing is. Concurrent
    /// callers share one run, and the run outlives a caller whose view was torn
    /// down mid-flight — see `InFlightRequests`.
    func ensureAlbumLoaded(albumId: String) async throws {
        if let album = store.albums[albumId], album.detailsLoaded, album.tracksLoaded {
            return
        }

        try await albumRequests.run(albumId) {
            try await self.loadAlbum(albumId: albumId)
        }
    }

    /// Loads an album and its tracks in **one** request.
    ///
    /// The Web API needed two, and the two-branch shape this replaces existed to skip the
    /// details half when the store already had them. `getAlbum` returns details and tracks
    /// together, so there is no half to skip — an album whose details are cached but whose
    /// tracks are not costs the same request either way, and asking once is simpler than
    /// arranging not to.
    private func loadAlbum(albumId: String) async throws {
        let union = try await partnerAPI.album(id: albumId)

        guard let (album, tracks) = union.entities() else {
            throw PartnerAPIError.emptyPayload
        }

        store.upsertAlbum(album)
        store.upsertTracks(tracks)

        // `getAlbum` reports how many tracks the album has, and the request does not page. A
        // short read would otherwise be a silently truncated album.
        if let total = union.tracksV2?.totalCount, total > tracks.count {
            debugLog("AlbumService", "album \(albumId) returned \(tracks.count) of \(total) tracks")
        }
    }

    // MARK: - Library Management

    /// Save an album to the user's library.
    ///
    /// The same mutation that saves a track or follows an artist — only the uri prefix differs.
    /// Kept as its own method anyway, because what happens *around* the call is per-kind: this
    /// one updates the album list, and the views calling it know nothing about uris.
    func saveAlbumToLibrary(albumId: String) async throws {
        try await partnerAPI.addToLibrary(uris: ["spotify:album:\(albumId)"])

        // Update store on success
        store.addAlbumToUserLibrary(albumId)
    }

    /// Remove an album from the user's library
    func removeAlbumFromLibrary(albumId: String) async throws {
        try await partnerAPI.removeFromLibrary(uris: ["spotify:album:\(albumId)"])

        // Update store on success
        store.removeAlbumFromUserLibrary(albumId)
    }
}
