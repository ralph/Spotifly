//
//  SPClient.swift
//  SwiftLibrespot
//
//  HTTP client for Spotify spclient endpoints
//  Handles track metadata and CDN URL resolution
//

import Foundation

/// HTTP client for Spotify spclient (storage/metadata) endpoints
public actor SPClient {
    // MARK: - Properties

    /// Signs each request like the desktop client, as the app's pages are signed, and shares
    /// their retries: once after a refused client token, and after a failure that may pass, with
    /// `retryPauses`.
    private let credentials: SpotifyCredentials
    private var spclientHost: String?
    private let deviceId: String
    /// Market and catalogue the batched-metadata requests must name.
    private var countryCode: String?
    private var catalogue = "premium"

    public func setCountryCode(_ code: String?) {
        countryCode = code
    }

    /// The pauses before a request that failed in a way that may pass is asked for again,
    /// shorter than a page's (`SpotifyCredentials.retryPauses`): a track's start waits on them,
    /// and a Next should not hang for seconds before it says it failed. librespot asks again
    /// with no pause at all.
    static let retryPauses: [Duration] = [.milliseconds(250), .seconds(1)]

    // MARK: - Initialization

    init(
        credentials: SpotifyCredentials,
        spclientHost: String? = nil,
        deviceId: String,
    ) {
        var credentials = credentials
        credentials.retryPauses = Self.retryPauses
        self.credentials = credentials
        self.spclientHost = spclientHost
        self.deviceId = deviceId

        debugLog("SPClient", "Initialized")
    }

    /// Reads a request, and throws `requestFailed` naming it unless it is answered 200.
    private nonisolated func fetch(_ request: URLRequest, named name: String) async throws -> Data {
        let (data, status) = try await credentials.read(request)
        guard status == 200 else {
            debugLog("SPClient", "\(name) failed: HTTP \(status), body: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            throw LibrespotError.requestFailed(name, status: status)
        }
        return data
    }

    // MARK: - Track Metadata

    /// Track metadata containing file information
    public struct TrackMetadata: Sendable {
        public let name: String
        public let durationMs: Int
        public let files: [AudioFile]

        public struct AudioFile: Sendable {
            public let fileId: Data
            public let format: AudioFormat
        }

        public enum AudioFormat: Int, Sendable {
            case oggVorbis96 = 0
            case oggVorbis160 = 1
            case oggVorbis320 = 2
            case mp3256 = 3
            case mp3320 = 4
            case mp3160 = 5
            case mp3096 = 6
            case mp3160Enc = 7
            case aac24 = 8
            case aac48 = 9
            case flac = 10
            case unknown = -1

            /// Nominal bitrate in kbps, for matching a quality preference.
            var kbps: Int {
                switch self {
                case .oggVorbis96, .mp3096: 96
                case .oggVorbis160, .mp3160, .mp3160Enc: 160
                case .oggVorbis320, .mp3320: 320
                case .mp3256: 256
                case .aac24: 24
                case .aac48: 48
                case .flac: 1411
                case .unknown: 0
                }
            }
        }
    }

    /// A track's name, duration and playable files, in one request to the extended-metadata
    /// endpoint, whose `Track` carries all three; see
    /// `plans/done/track-load-waits-on-two-metadata-requests.md`.
    ///
    /// Request: `BatchedEntityRequest { 1: header, 2: { 1: uri, 2: { 1: TRACK_V4(10) } } }`
    /// Response: nested arrays whose leaf is a `google.protobuf.Any` wrapping the `Track`.
    public func getTrack(uri entityUri: String) async throws -> TrackMetadata {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let url = URL(string: "https://\(host)/extended-metadata/v0/extended-metadata")!

        debugLog("SPClient", "[POST] extended-metadata \(entityUri)")

        // A read sent as a POST, and asked again as one.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.buildTrackRequest(entityUri: entityUri, country: countryCode, catalogue: catalogue)
        // Not `trackNotFound` when it fails: a server error that outlasted the retries is no
        // fact about the track.
        let data = try await fetch(request, named: "Track metadata")

        // A track that does not exist answers HTTP 200 with no `Track`, and 404 in the entity's
        // own header: not found, not withheld. A withheld one has a `Track` with no files.
        guard let track = Self.parseTrackResponse(data) else {
            throw LibrespotError.trackNotFound(entityUri)
        }
        return track
    }

    /// Encodes the BatchedEntityRequest asking for one entity's `Track`.
    nonisolated static func buildTrackRequest(entityUri: String, country: String?, catalogue: String) -> Data {
        ProtobufWriter.message {
            // Header naming market + catalogue; without it the service
            // answers each entity with 410 Gone.
            $0.message(field: 1) { header in
                if let country {
                    header.string(field: 1, country)
                }
                header.string(field: 2, catalogue)
            }
            // EntityRequest { 1: uri, 2: query }. One EntityRequest may carry
            // several ExtensionQuery entries; some tracks only expose files
            // under one of the two kinds. Single TRACK_V4 query: batching a
            // second kind alongside it made the service answer with one 410
            // array instead of either payload.
            $0.message(field: 2) { entityRequest in
                entityRequest.string(field: 1, entityUri)
                entityRequest.message(field: 2) { $0.varint(field: 1, 10) } // TRACK_V4
            }
        }
    }

    /// The `Track` the answer wraps, or nil when it wraps none.
    nonisolated static func parseTrackResponse(_ data: Data) -> TrackMetadata? {
        // BatchedExtensionResponse { 2: arrays[] }
        for array in ProtobufReader.fields(in: data) where array.number == 2 {
            // EntityExtensionDataArray { 2: kind varint, 3: datas[] }
            for entry in array.fields where entry.number == 3 {
                // EntityExtensionData { 1: header{1 status}, 3: extension_data = Any }, and
                // google.protobuf.Any { 2: value }, the value a full `Track`
                if let track = entry.fields.last(3)?.fields.last(2) {
                    return trackMetadata(track.fields)
                }
                let status = entry.fields.last(1)?.fields.last(1)?.value
                debugLog("SPClient", "Extended metadata: no track, entity status \(status.map(String.init) ?? "none")")
            }
        }
        return nil
    }

    // MARK: - CDN URL Resolution

    /// CDN URL information for downloading audio
    public struct CDNUrl: Sendable {
        public let url: URL
        public let expiresAt: Date?
    }

    /// Resolve CDN URL for an audio file
    public func resolveCDNUrl(fileId: Data) async throws -> CDNUrl {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let fileIdHex = fileId.hexString

        let url = URL(string: "https://\(host)/storage-resolve/files/audio/interactive/\(fileIdHex)?alt=json")!

        debugLog("SPClient", "[GET] storage-resolve for \(fileIdHex.prefix(16))…")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request, named: "Storage resolve")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdnUrls = json["cdnurl"] as? [String],
              let firstUrl = cdnUrls.first,
              let cdnUrl = URL(string: firstUrl)
        else {
            throw LibrespotError.cdnError("Invalid storage resolve response")
        }

        debugLog("SPClient", "Resolved CDN URL: \(cdnUrl.host ?? "?")")

        return CDNUrl(url: cdnUrl, expiresAt: nil)
    }

    /// Reads the `Track` message: `{2 name, 7 duration, 12 files[], 13 alternative[]}`.
    private nonisolated static func trackMetadata(_ fields: [ProtobufField]) -> TrackMetadata {
        let name = fields.last(2)?.string ?? ""
        // `sint32` in metadata.proto. Read as a plain varint it was doubled:
        // 403518 ms for a track the decoder counts 8897582 frames of, 201.8 s.
        let duration = fields.last(7).map { Int(truncatingIfNeeded: $0.sint64) } ?? 0
        let files = playableFiles(inTrack: fields)

        debugLog("SPClient", "Parsed track: \(name), duration=\(duration)ms, files=\(files.count)")

        return TrackMetadata(name: name, durationMs: duration, files: files)
    }

    /// A `Track`'s playable files. They sit at `Track.file` (12); a relinked
    /// recording answers with an empty list plus its playable copy under
    /// `Track.alternative` (13) — which is the normal case for
    /// market-substituted tracks — so the alternatives' files stand in when
    /// the track has none of its own.
    ///
    /// Formats `AudioFormat` does not name are left out of that choice. When
    /// they are all there is, they are returned anyway, as `.unknown`: an empty
    /// list means Spotify withholds the track (`LibrespotError.trackUnavailable`),
    /// and a track in formats this player does not decode is not that.
    private nonisolated static func playableFiles(inTrack fields: [ProtobufField]) -> [TrackMetadata.AudioFile] {
        func files(of track: [ProtobufField]) -> [TrackMetadata.AudioFile] {
            track.filter { $0.number == 12 }.compactMap { audioFile($0.fields) }
        }
        func choice(_ own: [TrackMetadata.AudioFile], _ alternatives: [TrackMetadata.AudioFile]) -> [TrackMetadata.AudioFile] {
            own.isEmpty ? alternatives : own
        }

        let own = files(of: fields)
        let alternatives = fields.filter { $0.number == 13 }.flatMap { files(of: $0.fields) }
        let known = choice(own.filter { $0.format != .unknown }, alternatives.filter { $0.format != .unknown })
        return known.isEmpty ? choice(own, alternatives) : known
    }

    /// `AudioFile { 1: file_id, 2: format }`, or nil without a file id. A
    /// missing format, or one `AudioFormat` does not name, reads as `.unknown`.
    private nonisolated static func audioFile(_ fields: [ProtobufField]) -> TrackMetadata.AudioFile? {
        guard let fileId = fields.last(1)?.bytes else { return nil }
        let format = fields.last(2).flatMap { TrackMetadata.AudioFormat(rawValue: Int(truncatingIfNeeded: $0.value)) }
        return TrackMetadata.AudioFile(fileId: fileId, format: format ?? .unknown)
    }

    // MARK: - Context Resolution

    /// An ordered track list resolved from a context uri.
    public struct ResolvedContext: Sendable {
        public let tracks: [String]
        /// Each track's `uid`, beside `tracks`, or nil where the answer has none. A playlist's
        /// tracks have one, an album's none (measured 2026-09-30).
        public let uids: [String?]
        /// The answer's `metadata`, the context's name among it (`contextName`).
        public let metadata: [String: String]
    }

    /// Resolves an album, playlist, artist, or station uri into its tracks,
    /// via spclient's context resolver — the same source Spotify's own
    /// clients use, and one that handles every context shape uniformly.
    public func resolveContext(_ contextUri: String) async throws -> ResolvedContext {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let encodedUri = contextUri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contextUri

        debugLog("SPClient", "Resolving context: \(contextUri)")

        var allTracks: [String] = []
        var allUids: [String?] = []
        var metadata: [String: String] = [:]
        var nextPage: String? = "/context-resolve/v1/\(encodedUri)?device_id=\(deviceId)"
        var pageLimit = 10

        while let path = nextPage, pageLimit > 0 {
            pageLimit -= 1

            let url = URL(string: "https://\(host)\(path)")!
            debugLog("SPClient", "[GET] \(url.absoluteString.prefix(120))")
            var request = URLRequest(url: url)
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
            // The deadline is the page's, its retries included.
            let data = try await Self.withTimeout(seconds: 20) { [self, request] in
                try await fetch(request, named: "Context resolve")
            }
            debugLog("SPClient", "Context response received")

            #if DEBUG
                debugLog("SPClient", "Context response \(data.count) bytes: \(data.prefix(400).map { String(format: "%02x", $0) }.joined())")
            #endif
            let report = Self.parseContextReport(data)
            allTracks.append(contentsOf: report.tracks)
            allUids.append(contentsOf: report.uids)
            metadata.merge(report.metadata) { first, _ in first }
            nextPage = report.nextPageUrl.map { "/context-resolve/v1/\($0)" }
        }

        debugLog("SPClient", "Context resolved: \(allTracks.count) track(s)")

        return ResolvedContext(tracks: allTracks, uids: allUids, metadata: metadata)
    }

    /// The tracks autoplay goes on with after `contextUri`: a station for it, from
    /// `context-resolve/v1/autoplay`, seeded with tracks the context played, as librespot's
    /// `get_autoplay_context` and go-librespot's `ContextResolveAutoplay` ask for it. Its first
    /// page only, which go-librespot plays too.
    public func resolveAutoplay(contextUri: String, recentTrackUris: [String]) async throws -> ResolvedContext {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        debugLog("SPClient", "Resolving autoplay for \(contextUri), \(recentTrackUris.count) track(s) as its seed")

        var request = URLRequest(url: URL(string: "https://\(host)/context-resolve/v1/autoplay")!)
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.autoplayRequest(contextUri: contextUri, recentTrackUris: recentTrackUris)
        let data = try await Self.withTimeout(seconds: 20) { [self, request] in
            try await fetch(request, named: "Autoplay resolve")
        }

        let report = Self.parseContextReport(data)
        debugLog("SPClient", "Autoplay resolved: \(report.tracks.count) track(s)")
        return ResolvedContext(tracks: report.tracks, uids: report.uids, metadata: report.metadata)
    }

    /// `AutoplayContextRequest { required string context_uri = 1; repeated string
    /// recent_track_uri = 2; }`. The answer is JSON, as a resolve's is.
    nonisolated static func autoplayRequest(contextUri: String, recentTrackUris: [String]) -> Data {
        ProtobufWriter.message {
            $0.string(field: 1, contextUri)
            for uri in recentTrackUris {
                $0.string(field: 2, uri)
            }
        }
    }

    /// Parses the context resolver's answer. Despite the protobuf `Accept`
    /// header the endpoint replies **JSON**: `{metadata, pages: [{tracks:
    /// [{uri, uid}], next_page_url}], uri}`.
    ///
    /// The top-level `uri` is the context's own, not a track's, so nothing
    /// here can say which track to start at. A start index was computed from
    /// it and was always 0 — the guard ran after the append, and a context uri
    /// never matches a track uri anyway. Removed rather than guessed at: which
    /// field, if any, carries a resume point has to come off a real response.
    nonisolated static func parseContextReport(_ data: Data) -> (tracks: [String], uids: [String?], nextPageUrl: String?, metadata: [String: String]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [], nil, [:])
        }

        var tracks: [String] = []
        var uids: [String?] = []
        var nextPageUrl: String?

        let pages = json["pages"] as? [[String: Any]] ?? []
        for page in pages {
            let pageTracks = page["tracks"] as? [[String: Any]] ?? []
            for track in pageTracks {
                guard let uri = track["uri"] as? String else { continue }
                tracks.append(uri)
                uids.append((track["uid"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            if nextPageUrl == nil {
                nextPageUrl = page["next_page_url"] as? String
            }
        }

        // String values only, as the player state's `context_metadata` is a map of strings.
        let metadata = (json["metadata"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return (tracks, uids, nextPageUrl, metadata)
    }

    // MARK: - Timeout

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LibrespotError.timeout("Request timed out after \(seconds)s")
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                // Without this, a thrown deadline awaits the request child —
                // which only ends once URLSession notices its own timeout.
                group.cancelAll()
                throw error
            }
        }
    }
}

// MARK: - Format Helpers

extension SPClient.TrackMetadata.AudioFormat {
    /// Whether the format is Ogg Vorbis — the only family this app decodes.
    nonisolated var isVorbis: Bool {
        switch self {
        case .oggVorbis96, .oggVorbis160, .oggVorbis320: true
        default: false
        }
    }
}
