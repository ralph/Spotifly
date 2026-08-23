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
    private let clientTokenProvider: (@Sendable () async throws -> String)?
    private var spclientHost: String?
    private let deviceId: String
    /// Market and catalogue the batched-metadata requests must name.
    private var countryCode: String?
    private var catalogue = "premium"

    public func setCountryCode(_ code: String?) {
        countryCode = code
    }

    // MARK: - Initialization

    public init(
        tokenProvider: @escaping @Sendable () async throws -> String,
        clientTokenProvider: (@Sendable () async throws -> String)? = nil,
        spclientHost: String? = nil,
        deviceId: String,
    ) {
        self.tokenProvider = tokenProvider
        self.clientTokenProvider = clientTokenProvider
        self.spclientHost = spclientHost
        self.deviceId = deviceId

        debugLog("SPClient", "Initialized")
    }

    /// Signs like the desktop client does: these hosts are no public API, and
    /// the requests they answer are the ones shaped like the client's own —
    /// bearer for the user, client token for the application, plus the
    /// platform/origin markers.
    private func authorizedRequest(url: URL, accept: String) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("OSX_ARM64", forHTTPHeaderField: "App-Platform")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com/", forHTTPHeaderField: "Referer")

        let token = try await tokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let clientTokenProvider {
            try await request.setValue(clientTokenProvider(), forHTTPHeaderField: "Client-Token")
        }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Track Metadata

    /// Track metadata containing file information
    public struct TrackMetadata: Sendable {
        public let gid: Data
        public let name: String
        public let durationMs: Int
        public var files: [AudioFile]

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
            debugLog("SPClient", "Track metadata request failed: HTTP \(httpResponse.statusCode), body: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            throw LibrespotError.trackNotFound(gidHex)
        }

        // Parse protobuf response
        return try parseTrackMetadata(data, gid: trackId)
    }

    // MARK: - Extended Metadata (audio files)

    /// Fetches a track's playable audio files via the extended-metadata
    /// endpoint. `/metadata/4` answers with a stub (title, duration, no
    /// files) these days — the files only come from here.
    ///
    /// Request: `BatchedEntityRequest { 2: { 1: uri, 2: { 1: AUDIO_FILES(5) } } }`
    /// Response: nested arrays whose leaf is a `google.protobuf.Any` wrapping
    /// `AudioFilesExtensionResponse { 1: files[] { 1: file, 4: bitrate } }`.
    public func getAudioFiles(entityUri: String) async throws -> [TrackMetadata.AudioFile] {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let url = URL(string: "https://\(host)/extended-metadata/v0/extended-metadata")!

        debugLog("SPClient", "[POST] extended-metadata \(entityUri)")

        var request = try await authorizedRequest(url: url, accept: "application/x-protobuf")
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.buildAudioFilesRequest(
            entityUri: entityUri,
            country: countryCode,
            catalogue: catalogue,
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibrespotError.cdnError("Invalid extended-metadata response")
        }

        guard httpResponse.statusCode == 200 else {
            debugLog("SPClient", "Extended metadata failed: HTTP \(httpResponse.statusCode), body: \(String(data: data.prefix(160), encoding: .utf8) ?? "?")")
            throw LibrespotError.trackNotFound(entityUri)
        }

        return Self.parseAudioFilesResponse(data)
    }

    /// Encodes the BatchedEntityRequest asking for AUDIO_FILES on one entity.
    nonisolated static func buildAudioFilesRequest(entityUri: String, country: String?, catalogue: String) -> Data {
        // One EntityRequest may carry several ExtensionQuery entries; some
        // tracks only expose files under one of the two kinds.
        // Single TRACK_V4 query: batching a second kind alongside it made
        // the service answer with one 410 array instead of either payload.
        var queries = Data()
        queries.append(tag(field: 1, wireType: 0))
        queries.append(varint(10))

        // EntityRequest { 1: uri, 2: query }
        var entityRequest = Data()
        entityRequest.append(tag(field: 1, wireType: 2))
        entityRequest.append(varint(entityUri.utf8.count))
        entityRequest.append(contentsOf: entityUri.utf8)
        entityRequest.append(tag(field: 2, wireType: 2))
        entityRequest.append(varint(queries.count))
        entityRequest.append(queries)

        // Optional header naming market + catalogue; without it the service
        // answers each entity with 410 Gone.
        var header = Data()
        if let country {
            header.append(tag(field: 1, wireType: 2))
            header.append(varint(country.utf8.count))
            header.append(contentsOf: country.utf8)
        }
        header.append(tag(field: 2, wireType: 2))
        header.append(varint(catalogue.utf8.count))
        header.append(contentsOf: catalogue.utf8)

        var out = Data()
        out.append(tag(field: 1, wireType: 2))
        out.append(varint(header.count))
        out.append(header)
        out.append(tag(field: 2, wireType: 2))
        out.append(varint(entityRequest.count))
        out.append(entityRequest)
        return out
    }

    /// Walks the response nesting down to the wrapped `AudioFile`s.
    nonisolated static func parseAudioFilesResponse(_ data: Data) -> [TrackMetadata.AudioFile] {
        var result: [TrackMetadata.AudioFile] = []
        var arrayCount = 0
        var dataCount = 0

        // BatchedExtensionResponse { 2: arrays[] }
        forEachField(data) { field, payload in
            guard field == 2 else { return }
            arrayCount += 1

            // EntityExtensionDataArray { 2: kind varint, 3: datas[] }
            var kind = -1
            forEachField(payload) { arrayField, arrayChild in
                // EntityExtensionData { 1: header{1 status}, 3: Any{2 value} }
                guard arrayField == 3 else { return }
                dataCount += 1
                forEachField(arrayChild) { entryField, entryPayload in
                    // EntityExtensionData { 3: extension_data = Any }
                    guard entryField == 3 else { return }
                    dataCount += 1
                    forEachField(entryPayload) { anyField, anyPayload in
                        // google.protobuf.Any { 2: value }
                        guard anyField == 2 else { return }
                        result += parseAudioFilesExtension(anyPayload)
                    }
                }
            }
        }

        debugLog("SPClient", "Extended metadata: \(arrayCount) array(s), \(dataCount) data(s), yielded \(result.count) file(s)")
        return result
    }

    /// The Any payload is a full `Track`. Playable files sit at
    /// `Track.file` (12); a relinked recording answers with an empty list
    /// plus its playable copy under `Track.alternative` (13) — which is the
    /// normal case for market-substituted tracks.
    private nonisolated static func parseAudioFilesExtension(_ data: Data) -> [TrackMetadata.AudioFile] {
        var ownFiles: [TrackMetadata.AudioFile] = []
        var alternativeFiles: [TrackMetadata.AudioFile] = []

        forEachField(data) { field, payload in
            switch field {
            case 12:
                if let file = parseAudioFileMessage(payload) {
                    ownFiles.append(file)
                }
            case 13:
                alternativeFiles += filesInsideTrack(payload)
            default:
                break
            }
        }

        return ownFiles.isEmpty ? alternativeFiles : ownFiles
    }

    /// Walks a nested `Track`, returning every `file` entry.
    private nonisolated static func filesInsideTrack(_ data: Data) -> [TrackMetadata.AudioFile] {
        var files: [TrackMetadata.AudioFile] = []

        forEachField(data) { field, payload in
            guard field == 12 else { return }
            if let file = parseAudioFileMessage(payload) {
                files.append(file)
            }
        }

        return files
    }

    /// `AudioFile { 1: file_id bytes, 2: format }`.
    ///
    /// Walked by hand rather than through `forEachField`, which only delivers
    /// length-delimited fields — the format arrives as a varint and would be
    /// silently dropped, failing every file on the enum guard.
    private nonisolated static func parseAudioFileMessage(_ data: Data) -> TrackMetadata.AudioFile? {
        var fileId: Data?
        var formatInt: UInt64 = 99

        var offset = 0
        while offset < data.count, offset >= 0 {
            // readTag already decodes the tag; shifting again turned every
            // AudioFile field into "unknown field 0".
            let (fieldNumber, wireType, newOffset) = readTagStatic(data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 2):
                let (bytes, next) = readLengthDelimitedStatic(data, offset: offset)
                fileId = bytes
                offset = next
            case (2, 0):
                let (value, next) = readVarintStatic(data, offset: offset)
                formatInt = value
                offset = next
            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        guard let fid = fileId,
              let format = TrackMetadata.AudioFormat(rawValue: Int(formatInt))
        else { return nil }

        return TrackMetadata.AudioFile(fileId: fid, format: format)
    }

    /// Tiny protobuf walker: calls `visit(fieldNumber, payload)` per
    /// length-delimited field. Non-length fields are skipped.
    private nonisolated static func forEachField(
        _ data: Data,
        _ visit: (Int, Data) -> Void,
    ) {
        var offset = 0
        while offset < data.count {
            let (tagValue, nextOffset) = readVarintStatic(data, offset: offset)
            offset = nextOffset
            let fieldNumber = Int(tagValue >> 3)
            let wireType = Int(tagValue & 0x7)

            switch wireType {
            case 2:
                let (length, lenOffset) = readVarintStatic(data, offset: offset)
                let start = lenOffset
                let end = start + Int(length)
                guard end <= data.count else { return }
                visit(fieldNumber, data.subdata(in: start ..< end))
                offset = end
            case 0:
                let (_, newOffset) = readVarintStatic(data, offset: offset)
                offset = newOffset
            case 1:
                offset += 8
            case 5:
                offset += 4
            default:
                return
            }
        }
    }

    private nonisolated static func varint(_ value: Int) -> Data {
        varint(UInt64(value))
    }

    private nonisolated static func tag(field: Int, wireType: Int) -> Data {
        varint(UInt64((field << 3) | wireType))
    }

    private nonisolated static func varint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v > 127 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
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

        let request = try await authorizedRequest(url: url, accept: "application/json")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw LibrespotError.cdnError("Storage resolve failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

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

    /// Parses the `Track` message: `{2 name, 7 duration, 12 files[]}`.
    private func parseTrackMetadata(_ data: Data, gid: Data) throws -> TrackMetadata {
        var name = ""
        var duration = 0
        var files: [TrackMetadata.AudioFile] = []
        var alternativeFiles: [TrackMetadata.AudioFile] = []

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = Self.readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 2:
                let (str, nextOffset) = Self.readString(data, offset: offset)
                name = str
                offset = nextOffset
            case 7:
                let (value, nextOffset) = Self.readVarint(data, offset: offset)
                duration = Int(value)
                offset = nextOffset
            case 12:
                let (fileData, nextOffset) = Self.readLengthDelimited(data, offset: offset)
                if let audioFile = parseAudioFile(fileData) {
                    files.append(audioFile)
                }
                offset = nextOffset
            case 13:
                // Relinked recordings keep their playable files under `alternative`.
                let (altData, nextOffset) = Self.readLengthDelimited(data, offset: offset)
                alternativeFiles += Self.parseAlternativeFiles(altData)
                offset = nextOffset
            default:
                offset = Self.skipField(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        // A relinked gid answers with an empty file list plus the playable
        // copy under `alternative`.
        if files.isEmpty {
            files = alternativeFiles
        }

        debugLog("SPClient", "Parsed track: \(name), duration=\(duration)ms, files=\(files.count)")

        return TrackMetadata(gid: gid, name: name, durationMs: duration, files: files)
    }

    /// Collects just the audio files out of a nested `Track` message.
    private nonisolated static func parseAlternativeFiles(_ data: Data) -> [TrackMetadata.AudioFile] {
        var files: [TrackMetadata.AudioFile] = []

        var offset = 0
        while offset < data.count, offset >= 0 {
            let (fieldNumber, wireType, newOffset) = readTagStatic(data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (12, 2):
                let (fileData, next) = readLengthDelimitedStatic(data, offset: offset)
                if let audioFile = parseAudioFileStatic(fileData) {
                    files.append(audioFile)
                }
                offset = next
            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        return files
    }

    private nonisolated static func parseAudioFileStatic(_ data: Data) -> TrackMetadata.AudioFile? {
        var fileId: Data?
        var format: TrackMetadata.AudioFormat = .unknown

        var offset = 0
        while offset < data.count, offset >= 0 {
            let (fieldNumber, wireType, newOffset) = readTagStatic(data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 2):
                let (bytes, next) = readLengthDelimitedStatic(data, offset: offset)
                fileId = bytes
                offset = next
            case (2, 0):
                let (value, next) = readVarintStatic(data, offset: offset)
                format = TrackMetadata.AudioFormat(rawValue: Int(value)) ?? .unknown
                offset = next
            default:
                offset = skipFieldStatic(data, offset: offset, wireType: wireType)
            }

            if offset < 0 {
                break
            }
        }

        guard let fid = fileId else { return nil }
        return TrackMetadata.AudioFile(fileId: fid, format: format)
    }

    /// Parses an `AudioFile`: `{1 file_id, 2 format}`.
    private func parseAudioFile(_ data: Data) -> TrackMetadata.AudioFile? {
        var fileId: Data?
        var format: TrackMetadata.AudioFormat = .unknown

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = Self.readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 1:
                let (bytes, nextOffset) = Self.readLengthDelimited(data, offset: offset)
                fileId = bytes
                offset = nextOffset
            case 2:
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

    // MARK: - Context Resolution

    /// An ordered track list resolved from a context uri.
    public struct ResolvedContext: Sendable {
        public let uri: String
        public let tracks: [String]
    }

    /// Resolves an album, playlist, artist, or station uri into its tracks,
    /// via spclient's context resolver — the same source Spotify's own
    /// clients use, and one that handles every context shape uniformly.
    public func resolveContext(_ contextUri: String) async throws -> ResolvedContext {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let encodedUri = contextUri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contextUri

        debugLog("SPClient", "Resolving context: \(contextUri)")

        var allTracks: [String] = []
        var nextPage: String? = "/context-resolve/v1/\(encodedUri)?device_id=\(deviceId)"
        var pageLimit = 10

        while let path = nextPage, pageLimit > 0 {
            pageLimit -= 1

            let url = URL(string: "https://\(host)\(path)")!
            debugLog("SPClient", "[GET] \(url.absoluteString.prefix(120))")
            debugLog("SPClient", "Signing context request…")
            let request = try await authorizedRequest(url: url, accept: "application/x-protobuf")
            debugLog("SPClient", "Sending context request…")

            let (data, response) = try await Self.withTimeout(seconds: 20) {
                try await URLSession.shared.data(for: request)
            }
            debugLog("SPClient", "Context response received")

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                debugLog("SPClient", "Context resolve FAILED: HTTP \(status), body: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
                throw LibrespotError.cdnError("Context resolve failed: HTTP \(status)")
            }

            #if DEBUG
                debugLog("SPClient", "Context response \(data.count) bytes: \(data.prefix(400).map { String(format: "%02x", $0) }.joined())")
            #endif
            let report = Self.parseContextReport(data)
            allTracks.append(contentsOf: report.tracks)
            nextPage = report.nextPageUrl.map { "/context-resolve/v1/\($0)" }
        }

        debugLog("SPClient", "Context resolved: \(allTracks.count) track(s)")

        return ResolvedContext(uri: contextUri, tracks: allTracks)
    }

    /// Parses the context resolver's answer. Despite the protobuf `Accept`
    /// header the endpoint replies **JSON**: `{metadata, pages: [{tracks:
    /// [{uri}], next_page_url}], uri}`.
    ///
    /// The top-level `uri` is the context's own, not a track's, so nothing
    /// here can say which track to start at. A start index was computed from
    /// it and was always 0 — the guard ran after the append, and a context uri
    /// never matches a track uri anyway. Removed rather than guessed at: which
    /// field, if any, carries a resume point has to come off a real response.
    private nonisolated static func parseContextReport(_ data: Data) -> (tracks: [String], nextPageUrl: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }

        var tracks: [String] = []
        var nextPageUrl: String?

        let pages = json["pages"] as? [[String: Any]] ?? []
        for page in pages {
            let pageTracks = page["tracks"] as? [[String: Any]] ?? []
            tracks.append(contentsOf: pageTracks.compactMap { $0["uri"] as? String })
            if nextPageUrl == nil {
                nextPageUrl = page["next_page_url"] as? String
            }
        }

        return (tracks, nextPageUrl)
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

    private nonisolated static func readVarintStatic(_ data: Data, offset: Int) -> (value: UInt64, newOffset: Int) {
        readVarint(data, offset: offset)
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
