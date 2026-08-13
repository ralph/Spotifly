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

    /// How many metadata requests are allowed to be in the air at once.
    ///
    /// `metadata/4` addresses one entity per request, where the Web API's `/v1/tracks` took
    /// fifty ids at a time, so a queue hydration that was one request is now one per track.
    /// Capped rather than unbounded: a fifty-track batch fired at once is a burst Spotify has
    /// no reason to tolerate, and the waves cost little when the requests are small.
    ///
    /// The batching endpoint the real client uses for this is `extended-metadata`, which is
    /// protobuf and deliberately out of scope until the Swift playback track needs it
    /// (`plans/single-grant-partner-api.md`, task 6). Move this there if the request volume
    /// ever shows up.
    static let metadataConcurrency = 8

    /// Track metadata for many ids, keyed by the id that was asked for.
    ///
    /// Ids Spotify has no track for are absent from the result rather than an error, matching
    /// what `/v1/tracks` did with its positional nulls — callers read the absence as "asked,
    /// and there is nothing". Every other failure throws, because `TrackService` remembers an
    /// absent id and stops asking for it: a request that failed for a reason that might not
    /// recur must not be recorded as a track that does not exist.
    func tracks(ids: [String]) async throws -> [String: SpclientTrack] {
        guard !ids.isEmpty else { return [:] }

        var found: [String: SpclientTrack] = [:]

        for start in stride(from: 0, to: ids.count, by: Self.metadataConcurrency) {
            let wave = ids[start ..< min(start + Self.metadataConcurrency, ids.count)]

            try await withThrowingTaskGroup(of: (String, SpclientTrack?).self) { group in
                for id in wave {
                    group.addTask { try await (id, trackIfPresent(id: id)) }
                }
                for try await (id, track) in group {
                    guard let track else { continue }

                    found[id] = track
                }
            }
        }

        return found
    }

    /// Nil for the two cases that mean "there is no such track", so they can be told apart
    /// from a request that merely failed.
    private func trackIfPresent(id: String) async throws -> SpclientTrack? {
        do {
            return try await track(id: id)
        } catch let SpclientError.requestFailed(status) where status == 404 {
            return nil
        } catch SpclientError.invalidId {
            return nil
        }
    }

    // MARK: - Connect state

    /// Sends a player command to the device currently holding playback.
    ///
    /// Replaces the `/me/player/*` transport endpoints. `from` is this app's own device id and
    /// `to` is the active one — and the source segment is **not validated**: the backend derives
    /// it from the session, which is why librespot's own transfer passes its own id for both
    /// sides. Measured with three different `from` values on 2026-08-13, all accepted.
    func sendCommand(_ command: ConnectCommand, from: String, to: String) async throws {
        try await sendConnectRequest(
            method: "POST",
            path: "connect-state/v1/player/command/from/\(from)/to/\(to)",
            body: ConnectCommandEnvelope(command),
        )
    }

    /// Sets a remote device's volume. Its own path and its own verb, unlike every other command.
    func setVolume(percent: Int, from: String, to: String) async throws {
        try await sendConnectRequest(
            method: "PUT",
            path: "connect-state/v1/connect/volume/from/\(from)/to/\(to)",
            body: ConnectVolume(percent: percent),
        )
    }

    /// The one request shape connect-state takes.
    ///
    /// No preflight and no `market`, unlike `get` below: this is not a catalogue read, and the
    /// probe established that a bare authorized request is accepted. Failure is reported by
    /// status code rather than in the body — `404 DEVICE_NOT_FOUND` when the target is gone —
    /// so unlike the pathfinder mutations there is no 200-that-means-no to unpick.
    private func sendConnectRequest(
        method: String,
        path: String,
        body: some Encodable & Sendable,
    ) async throws {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        try await applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let urlString = request.url?.absoluteString ?? path
        debugLog("SpclientAPI", "[\(method)] \(urlString)")

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw SpclientError.malformedResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            debugLog(
                "SpclientAPI",
                "\(method) \(path) failed (HTTP \(http.statusCode)): \(String(decoding: data.prefix(200), as: UTF8.self))",
            )
            throw SpclientError.requestFailed(http.statusCode)
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

    /// The inverse, for the gids spclient uses to *reference* entities.
    ///
    /// A track's metadata names its album and artists by gid, and `AppStore` keys them by
    /// base62, so a track fetched here cannot link anywhere without this. Nil rather than a
    /// best effort on anything that is not 32 hex characters: a mangled id addresses some
    /// other entity, and a nil album id merely leaves a track unlinked.
    static func base62(fromGID gid: String) -> String? {
        guard gid.count == 32 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = gid.startIndex
        while index < gid.endIndex {
            let next = gid.index(index, offsetBy: 2)
            guard let byte = UInt8(gid[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        // Long division by 62 over the 16 bytes, least significant digit first, for the same
        // reason the forward direction multiplies: Swift has no 128-bit integer.
        var digits: [Character] = []
        while bytes.contains(where: { $0 != 0 }) {
            var remainder = 0
            for position in bytes.indices {
                let accumulated = remainder << 8 | Int(bytes[position])
                bytes[position] = UInt8(accumulated / 62)
                remainder = accumulated % 62
            }
            digits.append(alphabet[remainder])
        }

        // Spotify ids are a fixed 22 characters, zero-padded — `0000000000000000000001` is a
        // real id shape, and trimming it to "1" would not resolve.
        while digits.count < 22 {
            digits.append("0")
        }

        return String(digits.reversed())
    }
}
