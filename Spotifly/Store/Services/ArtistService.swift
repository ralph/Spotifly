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

    /// One run per artist ID — see `InFlightRequests`.
    private let artistRequests = InFlightRequests<Void>()

    /// The followed-artists list, whose pages are one run at a time under one key.
    private let listRequests = InFlightRequests<Void>()
    private static let listKey = "user-artists"

    /// Every artist path now runs on the keymaster grant, which `PartnerAPI` holds itself, so
    /// this service no longer takes a Web API token.
    private let partnerAPI: PartnerAPI

    init(
        store: AppStore,
        partnerAPI: PartnerAPI = PartnerAPI(),
    ) {
        self.store = store
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

        // Followed artists used to be the one cursor-paginated list in the app, because
        // `/me/following` took an `after` id rather than an offset. `libraryV3` pages by
        // offset like everything else, so the special case is gone.
        try await listRequests.run(Self.listKey) {
            try await self.store.loadLibraryPage(\.artistsPagination) { offset in
                let page = try await self.partnerAPI.libraryArtists(offset: offset)
                // See AlbumService.loadUserAlbums: a superseded run must not write.
                try Task.checkCancellation()

                let artists = page.entities.compactMap { Artist(pathfinder: $0) }
                self.store.upsertArtists(artists)

                let artistIds = artists.map(\.id)
                if offset == 0 {
                    self.store.setUserArtistIds(artistIds)
                } else {
                    self.store.appendUserArtistIds(artistIds)
                }

                return (page.items?.count ?? 0, page.totalCount ?? 0)
            }
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

    /// Follow an artist (add to followed artists).
    ///
    /// Following *is* saving, as far as this API is concerned: the same mutation that saves a
    /// track or an album, with an artist uri. The Web API's separate `/me/following` endpoints
    /// are gone.
    func followArtist(artistId: String) async throws {
        try await partnerAPI.addToLibrary(uris: ["spotify:artist:\(artistId)"])

        // Update store on success
        store.addArtistToUserLibrary(artistId)
    }

    /// Unfollow an artist (remove from followed artists)
    func unfollowArtist(artistId: String) async throws {
        try await partnerAPI.removeFromLibrary(uris: ["spotify:artist:\(artistId)"])

        // Update store on success
        store.removeArtistFromUserLibrary(artistId)
    }
}
