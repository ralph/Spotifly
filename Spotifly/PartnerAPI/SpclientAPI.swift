//
//  SpclientAPI.swift
//  Spotifly
//
//  The REST half of the client's own API, at spclient.wg.spotify.com.
//

import Foundation

nonisolated enum SpclientError: Error, LocalizedError {
    case invalidId(String)
    case preflightRejected(Int)
    case requestFailed(Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case let .invalidId(id):
            "\(id) is not a Spotify id"
        case let .preflightRejected(status):
            "Spotify rejected the preflight (HTTP \(status))"
        case let .requestFailed(status):
            "Spotify rejected the request (HTTP \(status))"
        case .malformedResponse:
            "The Spotify response could not be read"
        }
    }
}

/// Track metadata as `metadata/4` returns it.
///
/// Deliberately a partial view. The endpoint returns considerably more than this — licensor
/// uuids, catalogue insertion dates, per-format file ids — and decoding fields nothing reads
/// only creates work when Spotify adds another one.
nonisolated struct SpclientTrack: Decodable, Sendable {
    struct Artist: Decodable, Sendable {
        let gid: String?
        let name: String?
    }

    struct Album: Decodable, Sendable {
        struct CoverGroup: Decodable, Sendable {
            struct Image: Decodable, Sendable {
                let fileId: String?
                let width: Int?
                let height: Int?

                enum CodingKeys: String, CodingKey {
                    case fileId = "file_id"
                    case width
                    case height
                }
            }

            let image: [Image]?
        }

        let gid: String?
        let name: String?
        let coverGroup: CoverGroup?

        enum CodingKeys: String, CodingKey {
            case gid
            case name
            case coverGroup = "cover_group"
        }
    }

    let gid: String?
    let name: String?
    let album: Album?
    let artist: [Artist]?
    let duration: Int?
    let number: Int?
    let discNumber: Int?
    let hasLyrics: Bool?

    enum CodingKeys: String, CodingKey {
        case gid
        case name
        case album
        case artist
        case duration
        case number
        case discNumber = "disc_number"
        case hasLyrics = "has_lyrics"
    }

    var artistNames: [String] {
        (artist ?? []).compactMap(\.name)
    }
}

/// Reads metadata from `spclient.wg.spotify.com`.
///
/// Same two credentials as `PartnerAPI` — bearer plus client token — but plain REST rather than
/// persisted queries, which makes this the more stable half to depend on: there are no query
/// hashes to rotate, and an entity comes back whole rather than field-selected.
nonisolated struct SpclientAPI: Sendable {
    static let baseURL = URL(string: "https://spclient.wg.spotify.com/")!
    static let origin = "https://xpui.app.spotify.com"

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

    /// Track metadata for a base62 id, the form the rest of the app uses.
    func track(id: String) async throws -> SpclientTrack {
        guard let gid = SpotifyGID.gid(fromBase62: id) else {
            throw SpclientError.invalidId(id)
        }

        let url = Self.baseURL.appending(path: "metadata/4/track/\(gid)")
        let data = try await get(url)

        do {
            return try JSONDecoder().decode(SpclientTrack.self, from: data)
        } catch {
            throw SpclientError.malformedResponse
        }
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> Data {
        // The desktop client's web view sends a CORS preflight before these, and this endpoint
        // is served to that origin — so the sequence is mimicked rather than the request sent
        // bare. libspot does the same before metadata/4.
        try await preflight(url)

        var request = URLRequest(url: Self.withMarket(url))
        request.httpMethod = "GET"
        try await applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        debugLog("SpclientAPI", "[GET] \(request.url?.absoluteString ?? url.absoluteString)")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpclientError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw SpclientError.requestFailed(http.statusCode)
        }

        return data
    }

    func preflight(_ url: URL) async throws {
        var request = URLRequest(url: Self.withMarket(url))
        request.httpMethod = "OPTIONS"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("GET", forHTTPHeaderField: "Access-Control-Request-Method")
        request.setValue(
            "app-platform,authorization,client-token,spotify-app-version",
            forHTTPHeaderField: "Access-Control-Request-Headers",
        )
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")

        let (_, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpclientError.malformedResponse
        }
        guard http.statusCode < 400 else {
            throw SpclientError.preflightRejected(http.statusCode)
        }
    }

    private func applyHeaders(to request: inout URLRequest) async throws {
        request.setValue(PartnerAPI.appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        try await request.setValue("Bearer \(accessToken())", forHTTPHeaderField: "Authorization")
        try await request.setValue(clientToken(), forHTTPHeaderField: "Client-Token")
    }

    /// `market=from_token` resolves the catalogue against the account rather than the caller's
    /// IP, which is what makes the response match what the user can actually play.
    static func withMarket(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "market" }) else { return url }
        items.append(URLQueryItem(name: "market", value: "from_token"))
        components.queryItems = items
        return components.url ?? url
    }
}

/// Base62 ids to the hex "gid" spclient addresses entities by.
///
/// `spotify:track:6rqhFgbbKwnb9MLmUQDhG6` is the same 16 bytes as
/// `metadata/4/track/d49fcea6…`, written in a different base. The Web API speaks the first
/// form and spclient the second, so everything crossing between them passes through here.
nonisolated enum SpotifyGID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    static func gid(fromBase62 id: String) -> String? {
        guard !id.isEmpty, id.count <= 22 else { return nil }

        // 16 bytes, big-endian, built by repeated multiply-and-add. Avoids needing 128-bit
        // arithmetic, which Swift has no native type for.
        var bytes = [UInt8](repeating: 0, count: 16)

        for character in id {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }

            var carry = digit
            for index in stride(from: bytes.count - 1, through: 0, by: -1) {
                let value = Int(bytes[index]) * 62 + carry
                bytes[index] = UInt8(value & 0xFF)
                carry = value >> 8
            }

            // Anything left over does not fit in 16 bytes, so it was never a Spotify id.
            guard carry == 0 else { return nil }
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
