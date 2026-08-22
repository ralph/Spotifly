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

    /// Produces a current bearer token on demand, so long-lived sessions
    /// survive the hour-long lifetime of any single token.
    private let tokenProvider: @Sendable () async throws -> String
    private var spclientHost: String?
    private let deviceId: String

    // MARK: - Initialization

    public init(
        tokenProvider: @escaping @Sendable () async throws -> String,
        spclientHost: String? = nil,
        deviceId: String,
    ) {
        self.tokenProvider = tokenProvider
        self.spclientHost = spclientHost
        self.deviceId = deviceId

        debugLog("SPClient", "Initialized")
    }

    private func authorizedRequest(url: URL, accept: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Track Metadata

    /// Track metadata containing file information
    public struct TrackMetadata: Sendable {
        public let gid: Data
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

            /// Whether this app can decode the format (Ogg Vorbis only).
            var isDecodable: Bool {
                isVorbis
            }
        }
    }

    /// Get track metadata from spclient
    /// This fetches file IDs needed for audio key requests
    public func getTrackMetadata(trackId: Data) async throws -> TrackMetadata {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let gidHex = trackId.hexString

        let url = URL(string: "https://\(host)/metadata/4/track/\(gidHex)")!

        debugLog("SPClient", "[GET] \(url)")

        let request = try await authorizedRequest(url: url, accept: "application/x-protobuf")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibrespotError.cdnError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            debugLog("SPClient", "Track metadata request failed: HTTP \(httpResponse.statusCode)")
            throw LibrespotError.trackNotFound(gidHex)
        }

        // Parse protobuf response
        return try parseTrackMetadata(data, gid: trackId)
    }

    // MARK: - Context Resolution

    /// An ordered track list resolved from a context uri.
    public struct ResolvedContext: Sendable {
        public let uri: String
        public let tracks: [String]
        /// Index the context says to start at, when it carries one.
        public let startIndex: Int
    }

    /// Resolves an album, playlist, artist, or station uri into its tracks,
    /// via spclient's context resolver — the same source Spotify's own
    /// clients use, and one that handles every context shape uniformly.
    public func resolveContext(_ contextUri: String) async throws -> ResolvedContext {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let encodedUri = contextUri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contextUri

        debugLog("SPClient", "Resolving context: \(contextUri)")

        var allTracks: [String] = []
        var startIndex = 0
        var nextPage: String? = "/context/resolve/v2/\(encodedUri)?device_id=\(deviceId)"
        var pageLimit = 10

        while let path = nextPage, pageLimit > 0 {
            pageLimit -= 1

            let url = URL(string: "https://\(host)\(path)")!
            let request = try await authorizedRequest(url: url, accept: "application/x-protobuf")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw LibrespotError.cdnError("Context resolve failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }

            let report = Self.parseContextReport(data)
            allTracks.append(contentsOf: report.tracks)
            if allTracks.isEmpty, !report.startUri.isEmpty {
                startIndex = max(0, allTracks.firstIndex(of: report.startUri) ?? 0)
            }
            nextPage = report.nextPageUrl.map { "/context/resolve/v2/\($0)" }
        }

        debugLog("SPClient", "Context resolved: \(allTracks.count) track(s)")

        return ResolvedContext(uri: contextUri, tracks: allTracks, startIndex: startIndex)
    }

    private static func parseContextReport(_ data: Data) -> (tracks: [String], nextPageUrl: String?, startUri: String) {
        var tracks: [String] = []
        var nextPageUrl: String?
        var startUri = ""

        var offset = 0
        while offset < data.count, offset >= 0 {
            let (fieldNumber, wireType, nextOffset) = readTagStatic(data, offset: offset)
            offset = nextOffset

            switch (fieldNumber, wireType) {
            case (2, 2): // next_page_url
                let (bytes, next) = readLengthDelimitedStatic(data, offset: offset)
                nextPageUrl = String(data: bytes, encoding: .utf8)
                offset = next

            case (3, 2): // pages
                let (pageData, next) = readLengthDelimitedStatic(data, offset: offset)
                tracks.append(contentsOf: parseContextPage(pageData))
                offset = next

            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }
        }

        _ = startUri
        return (tracks, nextPageUrl, startUri)
    }

    private static func parseContextPage(_ data: Data) -> [String] {
        var uris: [String] = []

        var offset = 0
        while offset < data.count, offset >= 0 {
            let (fieldNumber, wireType, nextOffset) = readTagStatic(data, offset: offset)
            offset = nextOffset

            switch (fieldNumber, wireType) {
            case (3, 2): // items
                let (itemData, next) = readLengthDelimitedStatic(data, offset: offset)
                if let uri = parseContextItem(itemData) {
                    uris.append(uri)
                }
                offset = next

            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }
        }

        return uris
    }

    private static func parseContextItem(_ data: Data) -> String? {
        var uri: String?

        var offset = 0
        while offset < data.count, offset >= 0 {
            let (fieldNumber, wireType, nextOffset) = readTagStatic(data, offset: offset)
            offset = nextOffset

            switch (fieldNumber, wireType) {
            case (1, 2): // uri
                let (bytes, next) = readLengthDelimitedStatic(data, offset: offset)
                uri = String(data: bytes, encoding: .utf8)
                offset = next

            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }
        }

        return uri
    }

    /// Parse track metadata protobuf
    private func parseTrackMetadata(_ data: Data, gid: Data) throws -> TrackMetadata {
        // Simplified protobuf parsing for Track message
        // Field 1: gid (bytes)
        // Field 2: name (string)
        // Field 7: duration (int32)
        // Field 12: file (repeated AudioFile message)

        var name = ""
        var duration = 0
        var files: [TrackMetadata.AudioFile] = []

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = Self.readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 2: // name
                let (str, nextOffset) = Self.readString(data, offset: offset)
                name = str
                offset = nextOffset

            case 7: // duration
                let (value, nextOffset) = Self.readVarint(data, offset: offset)
                duration = Int(value)
                offset = nextOffset

            case 12: // file
                let (fileData, nextOffset) = Self.readLengthDelimited(data, offset: offset)
                if let audioFile = parseAudioFile(fileData) {
                    files.append(audioFile)
                }
                offset = nextOffset

            default:
                // Skip unknown fields
                offset = Self.skipField(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        debugLog("SPClient", "Parsed track: \(name), duration=\(duration)ms, files=\(files.count)")

        return TrackMetadata(
            gid: gid,
            name: name,
            durationMs: duration,
            files: files,
        )
    }

    /// Parse AudioFile message
    private func parseAudioFile(_ data: Data) -> TrackMetadata.AudioFile? {
        var fileId: Data?
        var format: TrackMetadata.AudioFormat = .unknown

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = Self.readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 1: // file_id
                let (bytes, nextOffset) = Self.readLengthDelimited(data, offset: offset)
                fileId = bytes
                offset = nextOffset

            case 2: // format
                let (value, nextOffset) = Self.readVarint(data, offset: offset)
                format = TrackMetadata.AudioFormat(rawValue: Int(value)) ?? .unknown
                offset = nextOffset

            default:
                offset = Self.skipField(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        guard let fid = fileId else { return nil }
        return TrackMetadata.AudioFile(fileId: fid, format: format)
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

        // Storage resolve endpoint
        let url = URL(string: "https://\(host)/storage-resolve/files/audio/interactive/\(fileIdHex)?alt=json")!

        debugLog("SPClient", "[GET] storage-resolve for \(fileIdHex.prefix(16))…")

        let request = try await authorizedRequest(url: url, accept: "application/json")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw LibrespotError.cdnError("Storage resolve failed")
        }

        // Parse JSON response
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

    // MARK: - Protobuf Helpers

    private nonisolated static func readTag(_ data: Data, offset: Int) -> (fieldNumber: Int, wireType: Int, newOffset: Int) {
        guard offset < data.count else { return (0, 0, -1) }

        let (tag, newOffset) = Self.readVarint(data, offset: offset)
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x7)

        return (fieldNumber, wireType, newOffset)
    }

    private nonisolated static func readVarint(_ data: Data, offset: Int) -> (value: UInt64, newOffset: Int) {
        var result: UInt64 = 0
        var shift = 0
        var currentOffset = offset

        while currentOffset < data.count {
            let byte = data[currentOffset]
            result |= UInt64(byte & 0x7F) << shift
            currentOffset += 1

            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        }

        return (result, currentOffset)
    }

    private nonisolated static func readLengthDelimited(_ data: Data, offset: Int) -> (data: Data, newOffset: Int) {
        let (length, newOffset) = Self.readVarint(data, offset: offset)
        let endOffset = newOffset + Int(length)

        guard endOffset <= data.count else {
            return (Data(), -1)
        }

        return (data.subdata(in: newOffset ..< endOffset), endOffset)
    }

    private nonisolated static func readString(_ data: Data, offset: Int) -> (string: String, newOffset: Int) {
        let (bytes, newOffset) = Self.readLengthDelimited(data, offset: offset)
        let string = String(data: bytes, encoding: .utf8) ?? ""
        return (string, newOffset)
    }

    private nonisolated static func skipField(_ data: Data, offset: Int, wireType: Int) -> Int {
        switch wireType {
        case 0: // Varint
            let (_, newOffset) = Self.readVarint(data, offset: offset)
            return newOffset
        case 1: // 64-bit
            return offset + 8
        case 2: // Length-delimited
            let (_, newOffset) = Self.readLengthDelimited(data, offset: offset)
            return newOffset
        case 5: // 32-bit
            return offset + 4
        default:
            return -1 // Unknown wire type
        }
    }

    private nonisolated static func readTagStatic(_ data: Data, offset: Int) -> (fieldNumber: Int, wireType: Int, newOffset: Int) {
        readTag(data, offset: offset)
    }

    private nonisolated static func readLengthDelimitedStatic(_ data: Data, offset: Int) -> (data: Data, newOffset: Int) {
        readLengthDelimited(data, offset: offset)
    }

    private nonisolated static func skipFieldStatic(_ data: Data, offset: Int, wireType: Int) -> Int {
        skipField(data, offset: offset, wireType: wireType)
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
