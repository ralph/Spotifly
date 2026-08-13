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

    /// One run per playlist ID — see `InFlightRequests`.
    private let playlistRequests = InFlightRequests<Void>()

    /// The user's playlist list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-playlists"

    /// The account's own profile, which the library writes address the rootlist by.
    private let profileRequests = InFlightRequests<Void>()
    private static let profileKey = "user-profile"

    /// The playlist reads and the item mutations. No token is passed in: both clients run on
    /// the keymaster grant and hold it themselves.
    private let partnerAPI: PartnerAPI

    /// The playlist's own existence — creating it, renaming it, and the library's list of
    /// them — which pathfinder has no operations for. See `PlaylistChanges.swift`.
    private let spclientAPI: SpclientAPI

    init(
        store: AppStore,
        partnerAPI: PartnerAPI = PartnerAPI(),
        spclientAPI: SpclientAPI = SpclientAPI(),
    ) {
        self.store = store
        self.partnerAPI = partnerAPI
        self.spclientAPI = spclientAPI
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
            self.store.playlistsPagination.isLoading = true
            defer {
                // Only if this run is still the one loading: a superseded run
                // must not clear the state its replacement just set.
                if !Task.isCancelled {
                    self.store.playlistsPagination.isLoading = false
                }
            }

            let page = try await self.partnerAPI.libraryPlaylists(offset: offset)
            // See AlbumService.loadUserAlbums: a superseded run must not write.
            try Task.checkCancellation()

            // Can be fewer than the page holds, so the offset advances by the page's item count
            // rather than by this one. Folders are excluded by asking for the list flattened
            // (see `PathfinderLibraryVariables`) rather than by being filtered here, which also
            // brings back the playlists nested inside them.
            let playlists = page.entities.compactMap { Playlist(pathfinder: $0) }
            self.store.upsertPlaylists(playlists)

            let playlistIds = playlists.map(\.id)
            if offset == 0 {
                self.store.setUserPlaylistIds(playlistIds)
            } else {
                self.store.appendUserPlaylistIds(playlistIds)
            }

            self.store.playlistsPagination.isLoaded = true
            self.store.playlistsPagination.advance(
                by: page.items?.count ?? 0,
                total: page.totalCount ?? 0,
            )
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

    /// Creates a playlist and lists it in the user's library.
    ///
    /// **Two writes where `POST /me/playlists` was one.** The playlist service makes the
    /// playlist and answers its uri; nothing puts it in the library until the rootlist is told
    /// to hold it. Measured 2026-08-14 — the web client sends both.
    func createPlaylist(name: String, description: String? = nil) async throws -> Playlist {
        let owner = try await requireProfile()

        let id = try await spclientAPI.createPlaylist(name: name, description: description)
        try await spclientAPI.addPlaylistToLibrary(username: owner.id, playlistId: id)

        // Built here rather than fetched back: everything a new playlist has is already known,
        // and it is empty by construction — so `tracksLoaded` is true in the strong sense, not
        // as an assumption. See the "cache what was fetched" rule in AGENTS.md.
        let playlist = Playlist(
            id: id,
            name: name,
            description: description,
            images: ImageSet(variants: []),
            uri: "spotify:playlist:\(id)",
            isPublic: false,
            ownerId: owner.id,
            ownerName: owner.displayName,
            externalUrl: nil,
            items: [],
            totalDurationMs: 0,
            knownTrackCount: 0,
            tracksLoaded: true,
        )

        store.addPlaylistToUserLibrary(playlist)
        return playlist
    }

    /// Renames a playlist, changes its description, or both.
    func updatePlaylistDetails(
        playlistId: String,
        name: String? = nil,
        description: String? = nil,
    ) async throws {
        try await spclientAPI.changePlaylistAttributes(
            id: playlistId,
            name: name,
            description: description,
        )

        store.updatePlaylistDetails(
            id: playlistId,
            name: name,
            description: description,
        )
    }

    /// Deletes a playlist — which is to say, drops it from the user's library.
    ///
    /// The same call as `unfollowPlaylist` below, and the Web API said so too: `DELETE
    /// /playlists/{id}/followers` served both. The two names are kept because the two menu
    /// items mean different things to the person clicking them.
    func deletePlaylist(playlistId: String) async throws {
        try await removeFromLibrary(playlistId: playlistId)
    }

    /// Stops following someone else's playlist.
    func unfollowPlaylist(playlistId: String) async throws {
        try await removeFromLibrary(playlistId: playlistId)
    }

    private func removeFromLibrary(playlistId: String) async throws {
        let owner = try await requireProfile()
        try await spclientAPI.removePlaylistFromLibrary(
            username: owner.id,
            playlistId: playlistId,
        )

        store.removePlaylistFromUserLibrary(playlistId)
    }

    /// Follows (saves) a playlist into the user's library.
    func followPlaylist(playlistId: String) async throws {
        let owner = try await requireProfile()
        try await spclientAPI.addPlaylistToLibrary(username: owner.id, playlistId: playlistId)

        store.addPlaylistToUserLibraryById(playlistId)
    }

    /// The rootlist is addressed by the account's own username, so library membership cannot be
    /// changed before the profile has loaded. `UserProfile.id` *is* the username — see
    /// `UserProfile.init(pathfinder:)`, which takes it straight from `profileAttributes`.
    ///
    /// **Fetches it rather than refusing.** The profile is loaded once at startup, on a path
    /// that deliberately swallows its own failure — an app that cannot say who you are is still
    /// an app that plays music — and nothing retried it. So one transient failure there left
    /// create, delete, follow and unfollow throwing `accountUnknown` until the app was
    /// relaunched, for a request none of them had ever made themselves. Through the registry,
    /// so several writes arriving at once ask for it once.
    private func requireProfile() async throws -> UserProfile {
        if let profile = store.userProfile {
            return profile
        }

        try await profileRequests.run(Self.profileKey) {
            let profile = try await self.partnerAPI.profile()
            self.store.setUserProfile(UserProfile(pathfinder: profile))
        }

        // A profile can arrive without the one field that matters — `UserProfile(pathfinder:)`
        // is failable precisely because a nameless account cannot address a rootlist.
        guard let profile = store.userProfile else {
            throw SpclientError.accountUnknown
        }
        return profile
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

    /// Remove **occurrences** from a playlist, named by uid.
    ///
    /// Not by track id, and there is deliberately no by-track-id variant to fall back to: a
    /// playlist can hold the same song more than once, the Web API path this replaces removed
    /// every copy of it, and the interim version here removed whichever copy came first. A uid
    /// names the row the user actually chose, and every caller now has one.
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
