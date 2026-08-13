//
//  PartnerAPI.swift
//  Spotifly
//
//  The GraphQL API the desktop client uses, at api-partner.spotify.com.
//

import Foundation

nonisolated enum PartnerAPIError: Error, LocalizedError {
    case requestFailed(Int, String)
    case persistedQueryNotFound(String)
    case graphQLErrors([String])
    case emptyPayload
    /// A write Spotify answered with HTTP 200 and a failure `__typename`.
    case mutationRejected(String, String)

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

/// Sends persisted queries to `api-partner.spotify.com`.
///
/// Authorized by the keymaster token *and* a client token: the bearer alone is a 401 here.
/// Both come from the single grant this app now performs — see
/// `plans/single-grant-partner-api.md`.
nonisolated struct PartnerAPI: Sendable {
    static let endpoint = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!

    /// The headers the desktop client sends. `App-Platform` and the xpui origin are not
    /// cosmetic — this endpoint is not a public API, and the requests that work are the ones
    /// shaped like the client's own.
    static let appPlatform = "OSX_ARM64"
    static let origin = "https://xpui.app.spotify.com"

    /// Injected so request construction and decoding can be tested without a network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let accessToken: @Sendable () async throws -> String
    private let clientToken: @Sendable () async throws -> String
    private let invalidateClientToken: @Sendable (String) async -> Void
    private let transport: Transport

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        clientToken: @escaping @Sendable () async throws -> String = {
            try await ClientTokenProvider.shared.token()
        },
        invalidateClientToken: @escaping @Sendable (String) async -> Void = {
            await ClientTokenProvider.shared.invalidate(rejected: $0)
        },
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
    ) {
        self.accessToken = accessToken
        self.clientToken = clientToken
        self.invalidateClientToken = invalidateClientToken
        self.transport = transport
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

        guard let album = response.data?.albumUnion else {
            throw PartnerAPIError.emptyPayload
        }

        return album
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

        guard let artist = response.data?.artistUnion else {
            throw PartnerAPIError.emptyPayload
        }

        return artist
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
        let first = try await playlistPage(uri: uri, offset: 0)

        var items = first.content?.items ?? []
        let total = first.content?.totalCount ?? items.count

        while items.count < total {
            let page = try await playlistPage(uri: uri, offset: items.count)
            let next = page.content?.items ?? []
            // A page that adds nothing ends the walk rather than repeating it forever: the
            // playlist can lose items between requests, and `totalCount` would then name a
            // length no offset ever reaches.
            guard !next.isEmpty else { break }
            items += next
        }

        return first.withItems(items)
    }

    private func playlistPage(uri: String, offset: Int) async throws -> PathfinderPlaylistUnion {
        let response: PathfinderPlaylistResponse = try await query(
            .fetchPlaylist,
            variables: PathfinderPlaylistVariables(uri: uri, offset: offset),
        )

        guard let playlist = response.data?.playlistV2 else {
            throw PartnerAPIError.emptyPayload
        }

        return playlist
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

    /// One page of the user's saved tracks.
    func libraryTracks(offset: Int, limit: Int = 50) async throws -> PathfinderLibraryTrackPage {
        let response: PathfinderLibraryTracksResponse = try await query(
            .fetchLibraryTracks,
            variables: PathfinderLibraryTracksVariables(offset: offset, limit: limit),
        )

        guard let page = response.page else {
            throw PartnerAPIError.emptyPayload
        }

        return page
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
    func query<Envelope: Decodable & Sendable>(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> Envelope {
        let sent = try await send(operation, variables: variables)

        // A 401 can be either credential, and the client token is the one nothing else would
        // notice: it is cached for the fortnight Spotify says it is good for, so a token
        // revoked before its stated expiry fails every request until the app is relaunched.
        // The bearer refreshes itself, so this costs one wasted retry at worst.
        //
        // The token this request actually carried is named, not just "the current one" —
        // concurrent requests share a token, so one dead token is refused several times over
        // and the later refusals would otherwise discard the replacement the first one fetched.
        if sent.status == 401 {
            if let rejected = sent.clientToken {
                await invalidateClientToken(rejected)
            }
            let retried = try await send(operation, variables: variables)
            guard retried.status == 200 else {
                throw Self.failure(operation: operation, status: retried.status, body: retried.body)
            }
            return try decode(retried.body, operation: operation)
        }

        guard sent.status == 200 else {
            throw Self.failure(operation: operation, status: sent.status, body: sent.body)
        }

        return try decode(sent.body, operation: operation)
    }

    /// One attempt, reporting the client token it carried so a refusal can name it.
    private func send(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> (body: Data, status: Int, clientToken: String?) {
        let request = try await makeRequest(operation, variables: variables)

        debugLog("PartnerAPI", "[POST] \(Self.endpoint.absoluteString) \(operation.name)")

        let (data, response) = try await transport(request)

        guard let http = response as? HTTPURLResponse else {
            throw PartnerAPIError.emptyPayload
        }

        return (data, http.statusCode, request.value(forHTTPHeaderField: "Client-Token"))
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
    /// query document — Spotify holds it, keyed by that hash.
    func makeRequest(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = try Self.encodeBody(operation, variables: variables)

        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")

        // Both, always. The bearer identifies the user, the client token the application, and
        // this host wants to see both.
        try await request.setValue("Bearer \(accessToken())", forHTTPHeaderField: "Authorization")
        try await request.setValue(clientToken(), forHTTPHeaderField: "Client-Token")

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
