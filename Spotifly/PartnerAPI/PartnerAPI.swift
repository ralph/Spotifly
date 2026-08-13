//
//  PartnerAPI.swift
//  Spotifly
//
//  The GraphQL API the desktop client uses, at api-partner.spotify.com.
//

import Foundation

nonisolated enum PartnerAPIError: Error, LocalizedError {
    case requestFailed(Int)
    case persistedQueryNotFound(String)
    case graphQLErrors([String])
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case let .requestFailed(status):
            "Spotify rejected the request (HTTP \(status))"
        case let .persistedQueryNotFound(operation):
            "Spotify no longer recognises the stored query for \(operation)"
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
    private let transport: Transport

    init(
        accessToken: @escaping @Sendable () async throws -> String = {
            try await KeymasterSession.shared.accessToken()
        },
        clientToken: @escaping @Sendable () async throws -> String = {
            try await ClientTokenProvider.shared.token()
        },
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
    ) {
        self.accessToken = accessToken
        self.clientToken = clientToken
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

    // MARK: - Transport

    func query<Payload: Decodable & Sendable>(
        _ operation: PathfinderOperation,
        variables: some Encodable & Sendable,
    ) async throws -> PathfinderResponse<Payload> {
        let request = try await makeRequest(operation, variables: variables)

        debugLog("PartnerAPI", "[POST] \(Self.endpoint.absoluteString) \(operation.name)")

        let (data, response) = try await transport(request)

        guard let http = response as? HTTPURLResponse else {
            throw PartnerAPIError.emptyPayload
        }
        guard http.statusCode == 200 else {
            throw PartnerAPIError.requestFailed(http.statusCode)
        }

        return try decode(data, operation: operation)
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
    func decode<Payload: Decodable & Sendable>(
        _ data: Data,
        operation: PathfinderOperation,
    ) throws -> PathfinderResponse<Payload> {
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

        return try JSONDecoder().decode(PathfinderResponse<Payload>.self, from: data)
    }
}
