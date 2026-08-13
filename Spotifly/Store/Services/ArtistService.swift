//
//  ArtistService.swift
//  Spotifly
//
//  Service for artist-related operations.
//  Handles API calls and updates AppStore on success.
//

import Foundation

@MainActor
@Observable
final class ArtistService {
    private let store: AppStore

    /// Used by the loading entry points, which often decide there is nothing to
    /// fetch. They take the token themselves, *after* deciding, so a cache hit
    /// costs nothing.
    private let tokenProvider: () async -> String

    /// One run per artist ID — see `InFlightRequests`.
    private let artistRequests = InFlightRequests<Void>()

    /// The followed-artists list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-artists"

    // How many albums an artist page shows. The endpoint is not paginated here.

    /// The artist reads, which take no token: `PartnerAPI` runs on the keymaster grant and
    /// holds it itself. `tokenProvider` is the Web API's, still needed by the followed-artists
    /// list and the follow/unfollow writes.
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

    // MARK: - User Artists (Followed)

    /// Load the next page of followed artists, or the first if none is loaded.
    func loadUserArtists(forceRefresh: Bool = false) async throws {
        // Skip if already loaded and not forcing refresh (but only if we actually have data)
        if store.artistsPagination.isLoaded, !forceRefresh, !store.artistsPagination.hasMore, !store.userArtistIds.isEmpty {
            return
        }

        if forceRefresh {
            listRequests.cancel(Self.listKey)
            store.artistsPagination.reset()
        }

        try await listRequests.run(Self.listKey) {
            // Artists use cursor-based pagination
            let cursor = self.store.artistsPagination.nextCursor
            let accessToken = await self.tokenProvider()
            self.store.artistsPagination.isLoading = true
            defer {
                // Only if this run is still the one loading: a superseded run
                // must not clear the state its replacement just set.
                if !Task.isCancelled {
                    self.store.artistsPagination.isLoading = false
                }
            }

            let response = try await SpotifyAPI.fetchUserArtists(
                accessToken: accessToken,
                limit: 20,
                after: cursor,
            )
            // See AlbumService.loadUserAlbums: a superseded run must not write.
            try Task.checkCancellation()

            let artists = response.artists.map { Artist(from: $0) }
            self.store.upsertArtists(artists)

            let artistIds = artists.map(\.id)
            if cursor == nil {
                self.store.setUserArtistIds(artistIds)
            } else {
                self.store.appendUserArtistIds(artistIds)
            }

            self.store.artistsPagination.isLoaded = true
            self.store.artistsPagination.hasMore = response.hasMore
            self.store.artistsPagination.nextCursor = response.nextCursor
            self.store.artistsPagination.total = response.total
        }
    }

    /// Load more artists (pagination)
    func loadMoreArtists() async throws {
        guard store.artistsPagination.hasMore, !listRequests.isRunning(Self.listKey) else {
            return
        }
        try await loadUserArtists()
    }

    // MARK: - Artist Details

    /// Makes sure the artist's details *and* their album list are in the store.
    ///
    /// The album list used to live in `ArtistDetailView`'s `@State`, so it was
    /// re-fetched on every visit and thrown away again. Now it is cached in the
    /// store like album and playlist tracks are, and a second visit issues nothing.
    /// Concurrent callers share one run, and the run outlives a caller whose view
    /// was torn down mid-flight — see `InFlightRequests`.
    func ensureArtistLoaded(artistId: String) async throws {
        guard store.artists[artistId] == nil || store.artistAlbumIds[artistId] == nil else { return }

        try await artistRequests.run(artistId) {
            try await self.loadArtist(artistId: artistId)
        }
    }

    /// Loads an artist and their discography.
    ///
    /// Two requests, because the operations divide that way: `queryArtistOverview` knows who
    /// the artist is but returns only a *sample* of releases — ten albums of fifteen for Daft
    /// Punk — while `queryArtistDiscographyAll` returns all thirty-seven and no profile. The
    /// artist page offers "show all", so it needs the full list. They run concurrently.
    private func loadArtist(artistId: String) async throws {
        async let overviewTask = partnerAPI.artist(id: artistId)
        async let discographyTask = partnerAPI.artistDiscography(id: artistId)
        let (overview, discography) = try await (overviewTask, discographyTask)

        guard let artist = Artist(pathfinderOverview: overview) else {
            throw PartnerAPIError.emptyPayload
        }

        store.upsertArtist(artist)
        storeReleases(discography.releases, for: artist)
    }

    /// Stores an artist's releases and records their order under the artist.
    ///
    /// The releases carry no artist of their own — they are already nested under one — so the
    /// artist's identity is handed down, exactly as the album view hands its cover art to its
    /// tracks.
    private func storeReleases(_ releases: [PathfinderRelease], for artist: Artist) {
        let albums = releases.compactMap {
            Album(pathfinderRelease: $0, artistId: artist.id, artistName: artist.name)
        }

        store.upsertAlbums(albums)
        store.setArtistAlbums(albums.map(\.id), for: artist.id)
    }

    // MARK: - Follow/Unfollow Artist

    /// Follow an artist (add to followed artists)
    func followArtist(artistId: String, accessToken: String) async throws {
        try await SpotifyAPI.followArtist(
            accessToken: accessToken,
            artistId: artistId,
        )

        // Update store on success
        store.addArtistToUserLibrary(artistId)
    }

    /// Unfollow an artist (remove from followed artists)
    func unfollowArtist(artistId: String, accessToken: String) async throws {
        try await SpotifyAPI.unfollowArtist(
            accessToken: accessToken,
            artistId: artistId,
        )

        // Update store on success
        store.removeArtistFromUserLibrary(artistId)
    }
}
