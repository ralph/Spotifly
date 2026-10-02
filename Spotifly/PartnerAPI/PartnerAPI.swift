//
//  PartnerAPI.swift
//  Spotifly
//
//  The GraphQL API the desktop client uses, at api-partner.spotify.com.
//

import Foundation

nonisolated enum PartnerAPIError: Error, LocalizedError, Equatable {
    case requestFailed(Int, String)
    case persistedQueryNotFound(String)
    case graphQLErrors([String])
    case emptyPayload
    /// A write Spotify answered with HTTP 200 and a failure `__typename`.
    case mutationRejected(String, String)
    /// Spotify has no such album, artist or playlist for this account, and says so with HTTP
    /// 200 and a union whose `__typename` is `NotFound`. Measured on 2026-09-29: an album from
    /// another market and an id that never existed answer alike. Asking again gets the same
    /// answer, so the views offer no retry; see `isRetryable(_:)`.
    case notFound(Entity)
    /// Spotify answered the album, artist or playlist with a failure `__typename` other than
    /// `NotFound`. Measured on 2026-09-29: a malformed playlist id answers HTTP 200 with
    /// `GenericError`, "Failed to fetch playlist for uri …, status code: 400 BAD_REQUEST", which
    /// is logged. It may be passing, so the views offer a retry.
    case entityFailed(Entity)

    enum Entity: Sendable {
        case album
        case artist
        case playlist
    }

    var errorDescription: String? {
        switch self {
        case let .requestFailed(status, detail):
            detail.isEmpty
                ? "Spotify rejected the request (HTTP \(status))"
                : "Spotify rejected the request (HTTP \(status)): \(detail)"
        case let .persistedQueryNotFound(operation):
            "Spotify no longer recognises the stored query for \(operation)"
        case let .mutationRejected(operation, reason):
            "Spotify rejected \(operation): \(reason)"
        case let .graphQLErrors(messages):
            messages.joined(separator: "; ")
        case .emptyPayload:
            "Spotify returned no data"
        case .notFound(.album):
            String(localized: "error.album_not_found")
        case .notFound(.artist):
            String(localized: "error.artist_not_found")
        case .notFound(.playlist):
            String(localized: "error.playlist_not_found")
        case .entityFailed(.album):
            String(localized: "error.album_failed")
        case .entityFailed(.artist):
            String(localized: "error.artist_failed")
        case .entityFailed(.playlist):
            String(localized: "error.playlist_failed")
        }
    }
}

/// The request body. At file scope rather than nested in the encoder, because the encoder
/// takes its variables as an opaque parameter and a generic type cannot be declared inside a
/// generic function.
private nonisolated struct PathfinderPersistedQuery: Encodable {
    let version = 1
    let sha256Hash: String
}

private nonisolated struct PathfinderExtensions: Encodable {
    let persistedQuery: PathfinderPersistedQuery
}

private nonisolated struct PathfinderRequestBody<Variables: Encodable>: Encodable {
    let variables: Variables
    let operationName: String
    let extensions: PathfinderExtensions
}

/// GraphQL reports failure inside a 200 body, so every response is checked for this first.
private nonisolated struct PathfinderErrorEnvelope: Decodable {
    struct Failure: Decodable {
        struct Extensions: Decodable {
            let code: String?
        }

        let message: String?
        let extensions: Extensions?
    }

    let errors: [Failure]?
}

/// What a pathfinder *write* answers with, on both the playlist and the library operations.
///
/// **A rejected mutation arrives as HTTP 200**, naming the failure in a `__typename` rather than
/// in a status code — `{"addItemsToPlaylist":{"__typename":"NotFound"}}` for a playlist that does
/// not exist. A client checking only the status would record the write as having happened and
/// never roll back its optimistic update. So success is recognised by name, and anything else is
/// a failure.
nonisolated struct PathfinderMutationResult: Decodable, Sendable {
    let typename: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case message
    }

    /// Nil when the mutation succeeded, otherwise what went wrong.
    ///
    /// Takes an optional because a response that named no result at all is itself a failure —
    /// an absent payload is not a write that happened.
    static func failure(_ result: Self?, unless successTypes: Set<String>) -> String? {
        guard let result, let typename = result.typename else {
            return "the response named no result"
        }
        guard !successTypes.contains(typename) else { return nil }

        return result.message.map { "\(typename): \($0)" } ?? typename
    }
}

/// An album, artist or playlist union: the entity, or what Spotify answered instead of it. See
/// `PartnerAPI.entity(_:kind:)`.
nonisolated protocol PathfinderEntityUnion {
    /// `Album`, `Artist` or `Playlist`, their kin such as `PreRelease`, or a failure such as
    /// `NotFound`.
    var typename: String? { get }
    /// What a failure says about itself.
    var message: String? { get }
}

/// Sends persisted queries to `api-partner.spotify.com`.
///
/// Authorized by the keymaster token *and* a client token: the bearer alone is a 401 here.
nonisolated struct PartnerAPI: Sendable {
    static let endpoint = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!

    typealias Transport = SpotifyCredentials.Transport

    private let credentials: SpotifyCredentials

    init(credentials: SpotifyCredentials = .live) {
        self.credentials = credentials
    }

    // MARK: - Searches

    func searchTracks(_ term: String, limit: Int = 30) async throws -> [PathfinderTrack] {
        let response: PathfinderResponse<PathfinderTrackResults> = try await query(
            .searchTracks,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.tracksV2?.entities ?? []
    }

    func searchAlbums(_ term: String, limit: Int = 30) async throws -> [PathfinderAlbum] {
        let response: PathfinderResponse<PathfinderAlbumResults> = try await query(
            .searchAlbums,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.albumsV2?.entities ?? []
    }

    func searchArtists(_ term: String, limit: Int = 30) async throws -> [PathfinderArtist] {
        let response: PathfinderResponse<PathfinderArtistResults> = try await query(
            .searchArtists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.artists?.entities ?? []
    }

    func searchPlaylists(_ term: String, limit: Int = 30) async throws -> [PathfinderPlaylist] {
        let response: PathfinderResponse<PathfinderPlaylistResults> = try await query(
            .searchPlaylists,
            variables: PathfinderSearchVariables(searchTerm: term, limit: limit),
        )
        return response.results?.playlists?.entities ?? []
    }

    // MARK: - Album

    /// An album's details *and* its track list, in one request.
    ///
    /// The Web API needed two — `/albums/{id}` and `/albums/{id}/tracks` — and this replaces
    /// both. spclient can also answer albums, but its `disc[].track[]` entries carry a `gid`
    /// and nothing else, so rendering one album would cost a request per track; measured
    /// against Discovery, that is fifteen requests instead of one.
    func album(id: String) async throws -> PathfinderAlbumUnion {
        let response: PathfinderAlbumResponse = try await query(
            .getAlbum,
            variables: PathfinderAlbumVariables(uri: "spotify:album:\(id)"),
        )

        return try Self.entity(response.data?.albumUnion, kind: .album)
    }

    // MARK: - Artist

    /// Who the artist is, plus a sample of their discography.
    func artist(id: String) async throws -> PathfinderArtistUnion {
        try await artistUnion(.queryArtistOverview, id: id)
    }

    /// Every release by an artist. Carries no profile — pair it with `artist(id:)`.
    func artistDiscography(id: String) async throws -> PathfinderArtistUnion {
        try await artistUnion(.queryArtistDiscographyAll, id: id)
    }

    private func artistUnion(
        _ operation: PathfinderOperation,
        id: String,
    ) async throws -> PathfinderArtistUnion {
        let response: PathfinderArtistResponse = try await query(
            operation,
            variables: PathfinderArtistVariables(uri: "spotify:artist:\(id)"),
        )

        return try Self.entity(response.data?.artistUnion, kind: .artist)
    }

    // MARK: - Playlist

    /// A playlist's details and all of its contents.
    ///
    /// **One request is one page.** `fetchPlaylist` caps its answer at `limit` items and reports
    /// the real length as `content.totalCount`, so a playlist longer than a page arrives
    /// silently truncated. The Web API path this replaces paginated to the end, and stopping at
    /// the first page hid every item past the 300th — not just from the list, but from removal
    /// and reordering, which can only name an item the app has seen.
    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        let uri = "spotify:playlist:\(id)"
        let first = try await playlistPage(variables: .init(uri: uri, offset: 0))

        var items = first.content?.items ?? []
        let total = first.content?.totalCount ?? items.count

        while items.count < total {
            let page = try await playlistPage(variables: .init(uri: uri, offset: items.count))
            let next = page.content?.items ?? []
            // A page that adds nothing ends the walk rather than repeating it forever: the
            // playlist can lose items between requests, and `totalCount` would then name a
            // length no offset ever reaches.
            guard !next.isEmpty else { break }
            items += next
        }

        return first.withItems(items)
    }

    /// A playlist's details with one of its items, for what changes without them: its cover.
    func playlistDetails(id: String) async throws -> PathfinderPlaylistUnion {
        try await playlistPage(variables: .init(uri: "spotify:playlist:\(id)", limit: 1))
    }

    private func playlistPage(
        _ operation: PathfinderOperation = .fetchPlaylist,
        variables: PathfinderPlaylistVariables,
    ) async throws -> PathfinderPlaylistUnion {
        let response: PathfinderPlaylistResponse = try await query(operation, variables: variables)

        return try Self.entity(response.data?.playlistV2, kind: .playlist)
    }

    /// The album, artist or playlist a union holds, or the error for what Spotify answered
    /// instead.
    ///
    /// The failures are named, not the successes. The web player's own code switches these
    /// unions on `PreRelease`, `PseudoPlaylist`, `RestrictedContent` and `UnknownType` besides
    /// `Album`, `Artist` and `Playlist` (read from its bundle on 2026-09-29), so accepting only
    /// the three would turn pages Spotify serves into errors. A kind that carries no entity is
    /// still caught by the services, as "Spotify returned no data".
    private static func entity<Union: PathfinderEntityUnion>(
        _ union: Union?,
        kind: PartnerAPIError.Entity,
    ) throws -> Union {
        guard let union else {
            throw PartnerAPIError.emptyPayload
        }
        switch union.typename {
        case "NotFound":
            throw PartnerAPIError.notFound(kind)
        case "GenericError":
            debugLog("PartnerAPI", "\(kind) failed: \(union.message ?? "no message")")
            throw PartnerAPIError.entityFailed(kind)
        default:
            return union
        }
    }

    func addToPlaylist(
        playlistId: String,
        trackUris: [String],
        position: PlaylistItemPosition = .bottom,
    ) async throws {
        try await mutate(.addToPlaylist, variables: PathfinderAddVariables(
            playlistUri: "spotify:playlist:\(playlistId)",
            playlistItemUris: trackUris,
            newPosition: position,
        ))
    }

    /// Removes the named **occurrences**, not every copy of a track.
    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        try await mutate(.removeFromPlaylist, variables: PathfinderRemoveVariables(
            playlistUri: "spotify:playlist:\(playlistId)",
            uids: uids,
        ))
    }

    func moveInPlaylist(
        playlistId: String,
        uids: [String],
        position: PlaylistItemPosition,
    ) async throws {
        try await mutate(.moveItemsInPlaylist, variables: PathfinderMoveVariables(
            playlistUri: "spotify:playlist:\(playlistId)",
            uids: uids,
            newPosition: position,
        ))
    }

    // MARK: - Library

    /// One page of the user's saved playlists.
    ///
    /// The page can hold **folders** as well as playlists — a library entry the app has no
    /// screen for — so it returns fewer entities than `totalCount` claims. See
    /// `PathfinderLibraryPage`.
    func libraryPlaylists(offset: Int, limit: Int = LibraryFilter.pageLimit) async throws
        -> PathfinderLibraryPage<PathfinderPlaylist>
    {
        try await libraryPage(filter: LibraryFilter.playlists, offset: offset, limit: limit)
    }

    func libraryAlbums(offset: Int, limit: Int = LibraryFilter.pageLimit) async throws
        -> PathfinderLibraryPage<PathfinderAlbum>
    {
        try await libraryPage(filter: LibraryFilter.albums, offset: offset, limit: limit)
    }

    func libraryArtists(offset: Int, limit: Int = LibraryFilter.pageLimit) async throws
        -> PathfinderLibraryPage<PathfinderArtist>
    {
        try await libraryPage(filter: LibraryFilter.artists, offset: offset, limit: limit)
    }

    /// One `libraryV3` request, typed to the kind its filter selects.
    ///
    /// Generic rather than three near-identical bodies, because the operation genuinely is one
    /// document: only `filters` differs, and the entity type follows from it.
    private func libraryPage<Entity: Decodable & Sendable>(
        filter: String,
        offset: Int,
        limit: Int,
    ) async throws -> PathfinderLibraryPage<Entity> {
        let response: PathfinderLibraryResponse<Entity> = try await query(
            .libraryV3,
            variables: PathfinderLibraryVariables(
                filters: [filter],
                offset: offset,
                limit: limit,
            ),
        )

        guard let page = response.page else {
            throw PartnerAPIError.emptyPayload
        }

        return page
    }

    /// One page of Liked Songs (`LikedSongs`), newest first. Contents only: a page of favorites
    /// never shows the playlist's own details.
    func likedSongs(
        offset: Int,
        limit: Int = LikedSongs.pageLimit,
    ) async throws -> PathfinderPlaylistUnion.Content {
        let page = try await playlistPage(
            .fetchPlaylistContents,
            variables: .init(uri: LikedSongs.uri, offset: offset, limit: limit),
        )

        guard let content = page.content else {
            throw PartnerAPIError.emptyPayload
        }

        return content
    }

    /// Which of these are in the library, keyed by id.
    ///
    /// A uri the service does not answer for is **left out** rather than reported false, so a
    /// truncated response leaves a track unresolved and asked about again instead of cached as
    /// "not saved".
    func entitiesInLibrary(uris: [String]) async throws -> [String: Bool] {
        guard !uris.isEmpty else { return [:] }

        let response: PathfinderLibraryMembershipResponse = try await query(
            .areEntitiesInLibrary,
            variables: PathfinderLibraryLookupVariables(uris: uris),
        )

        return response.statuses(for: uris)
    }

    /// Saves anything — a track, an album, an artist — by uri.
    func addToLibrary(uris: [String]) async throws {
        try await mutateLibrary(.addToLibrary, uris: uris)
    }

    func removeFromLibrary(uris: [String]) async throws {
        try await mutateLibrary(.removeFromLibrary, uris: uris)
    }

    private func mutateLibrary(_ operation: PathfinderOperation, uris: [String]) async throws {
        guard !uris.isEmpty else { return }

        let response: PathfinderLibraryMutationResponse = try await query(
            operation,
            variables: PathfinderLibraryWriteVariables(libraryItemUris: uris),
        )

        if let failure = response.failure {
            throw PartnerAPIError.mutationRejected(operation.name, failure)
        }
    }

    // MARK: - Home

    /// The start page, in one request.
    ///
    /// Everything the shelves draw arrives inline — names, cover art, artists — so this is the
    /// whole page rather than an index into it. That is the real saving over what it replaced:
    /// `/me/player/recently-played` named its items by uri only, so the strip cost one further
    /// request per album, playlist and artist on it.
    ///
    /// Throws `emptyPayload` when Spotify answers `GenericError`, which it does with HTTP 200
    /// and an otherwise well-formed body.
    func home() async throws -> PathfinderHome {
        let response: PathfinderHomeResponse = try await query(
            .home,
            variables: PathfinderHomeVariables(),
        )

        guard let home = response.home, !home.isError else {
            throw PartnerAPIError.emptyPayload
        }

        return home
    }

    // MARK: - Profile

    /// Who the listener is: id, display name and avatar.
    func profile() async throws -> PathfinderProfile {
        let response: PathfinderProfileResponse = try await query(
            .profileAttributes,
            variables: EmptyVariables(),
        )

        guard let profile = response.profile else {
            throw PartnerAPIError.emptyPayload
        }

        return profile
    }

    /// Runs a mutation and throws unless the response says it happened.
    ///
    /// A rejected mutation arrives as HTTP 200 with a `__typename` naming the failure, so the
    /// transport's status check cannot see it — without this, a failed write would look like a
    /// successful one and the optimistic update would stand.
    private func mutate(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws {
        let response: PathfinderMutationResponse = try await query(operation, variables: variables)

        if let failure = response.failure {
            throw PartnerAPIError.mutationRejected(operation.name, failure)
        }
    }

    // MARK: - Transport

    /// Generic over the whole envelope rather than over a search payload: `getAlbum` answers
    /// with `data.albumUnion`, not `data.searchV2`, so the shape below `data` is the
    /// operation's business. Search call sites name `PathfinderResponse<…>` and are unchanged.
    ///
    /// A failure that may pass is asked for again, unless the operation says not to; see
    /// `SpotifyCredentials.retryingPassingFailures(_:)`.
    func query<Envelope: Decodable & Sendable>(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> Envelope {
        let request = try makeRequest(operation, variables: variables)
        debugLog("PartnerAPI", "[POST] \(Self.endpoint.absoluteString) \(operation.name)")
        let sent = try await operation.retriesPassingFailures ? credentials.read(request) : credentials.send(request)

        guard sent.status == 200 else {
            throw Self.failure(operation: operation, status: sent.status, body: sent.body)
        }

        return try decode(sent.body, operation: operation)
    }

    private static func failure(
        operation: PathfinderOperation,
        status: Int,
        body data: Data,
    ) -> PartnerAPIError {
        // The body is the useful half of a rejection and was previously discarded. A 400
        // from this API names the variable it wanted and its type — the playlist page broke
        // on a missing `enableWatchFeedEntrypoint` and reported only "HTTP 400", sending the
        // next person to read code rather than the answer they had already been handed.
        let detail = String(decoding: data.prefix(500), as: UTF8.self)
        debugLog("PartnerAPI", "\(operation.name) failed (HTTP \(status)): \(detail)")
        return PartnerAPIError.requestFailed(status, detail)
    }

    /// Builds the request body: operation name, variables, and the persisted-query hash. No
    /// query document — Spotify holds it, keyed by that hash. Signed by `credentials` for each
    /// attempt.
    func makeRequest(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try Self.encodeBody(operation, variables: variables)

        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }

    static func encodeBody(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) throws -> Data {
        try JSONEncoder().encode(
            PathfinderRequestBody(
                variables: variables,
                operationName: operation.name,
                extensions: PathfinderExtensions(
                    persistedQuery: PathfinderPersistedQuery(sha256Hash: operation.sha256Hash),
                ),
            ),
        )
    }

    /// GraphQL reports failure in the body with a 200, so the payload has to be inspected even
    /// on success. A retired persisted query is called out by name, because that is the failure
    /// this design invites and "Spotify returned an error" would send the next person hunting.
    func decode<Envelope: Decodable & Sendable>(
        _ data: Data,
        operation: PathfinderOperation,
    ) throws -> Envelope {
        if let envelope = try? JSONDecoder().decode(PathfinderErrorEnvelope.self, from: data),
           let errors = envelope.errors,
           !errors.isEmpty
        {
            let retired = errors.contains { error in
                error.extensions?.code == "PERSISTED_QUERY_NOT_FOUND"
                    || (error.message?.localizedCaseInsensitiveContains("persistedquerynotfound") ?? false)
            }
            if retired {
                throw PartnerAPIError.persistedQueryNotFound(operation.name)
            }
            throw PartnerAPIError.graphQLErrors(errors.compactMap(\.message))
        }

        return try JSONDecoder().decode(Envelope.self, from: data)
    }
}
