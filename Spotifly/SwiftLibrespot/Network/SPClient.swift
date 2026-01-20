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

    private let accessToken: String
    private var spclientHost: String?
    private let session: URLSession

    // MARK: - Initialization

    public init(accessToken: String, spclientHost: String? = nil) {
        self.accessToken = accessToken
        self.spclientHost = spclientHost

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: config)

        debugLog("SPClient", "Initialized")
    }

    /// Set the spclient host from AP resolution
    public func setSpclientHost(_ host: String) {
        spclientHost = host
        debugLog("SPClient", "Using spclient host: \(host)")
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

            /// Preferred quality order (higher is better)
            public var qualityRank: Int {
                switch self {
                case .flac: 100
                case .oggVorbis320: 90
                case .mp3320: 85
                case .mp3256: 80
                case .oggVorbis160: 70
                case .mp3160: 65
                case .mp3160Enc: 60
                case .oggVorbis96: 50
                case .mp3096: 45
                case .aac48: 40
                case .aac24: 30
                case .unknown: 0
                }
            }
        }
    }

    /// Get track metadata from Mercury/spclient
    /// This fetches file IDs needed for audio key requests
    public func getTrackMetadata(trackId: Data) async throws -> TrackMetadata {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        let gidHex = trackId.hexString

        // Mercury-style endpoint via HTTP
        let url = URL(string: "https://\(host)/metadata/4/track/\(gidHex)")!

        debugLog("SPClient", "Fetching track metadata: \(gidHex)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

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
            let (fieldNumber, wireType, newOffset) = readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 2: // name
                let (str, nextOffset) = readString(data, offset: offset)
                name = str
                offset = nextOffset

            case 7: // duration
                let (value, nextOffset) = readVarint(data, offset: offset)
                duration = Int(value)
                offset = nextOffset

            case 12: // file
                let (fileData, nextOffset) = readLengthDelimited(data, offset: offset)
                if let audioFile = parseAudioFile(fileData) {
                    files.append(audioFile)
                }
                offset = nextOffset

            default:
                // Skip unknown fields
                offset = skipField(data, offset: offset, wireType: wireType)
            }

            if offset < 0 { break }
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
            let (fieldNumber, wireType, newOffset) = readTag(data, offset: offset)
            offset = newOffset

            switch fieldNumber {
            case 1: // file_id
                let (bytes, nextOffset) = readLengthDelimited(data, offset: offset)
                fileId = bytes
                offset = nextOffset

            case 2: // format
                let (value, nextOffset) = readVarint(data, offset: offset)
                format = TrackMetadata.AudioFormat(rawValue: Int(value)) ?? .unknown
                offset = nextOffset

            default:
                offset = skipField(data, offset: offset, wireType: wireType)
            }

            if offset < 0 { break }
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

        debugLog("SPClient", "Resolving CDN URL for file: \(fileIdHex.prefix(16))...")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

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

    private func readTag(_ data: Data, offset: Int) -> (fieldNumber: Int, wireType: Int, newOffset: Int) {
        guard offset < data.count else { return (0, 0, -1) }

        let (tag, newOffset) = readVarint(data, offset: offset)
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x7)

        return (fieldNumber, wireType, newOffset)
    }

    private func readVarint(_ data: Data, offset: Int) -> (value: UInt64, newOffset: Int) {
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

    private func readLengthDelimited(_ data: Data, offset: Int) -> (data: Data, newOffset: Int) {
        let (length, newOffset) = readVarint(data, offset: offset)
        let endOffset = newOffset + Int(length)

        guard endOffset <= data.count else {
            return (Data(), -1)
        }

        return (data.subdata(in: newOffset ..< endOffset), endOffset)
    }

    private func readString(_ data: Data, offset: Int) -> (string: String, newOffset: Int) {
        let (bytes, newOffset) = readLengthDelimited(data, offset: offset)
        let string = String(data: bytes, encoding: .utf8) ?? ""
        return (string, newOffset)
    }

    private func skipField(_ data: Data, offset: Int, wireType: Int) -> Int {
        switch wireType {
        case 0: // Varint
            let (_, newOffset) = readVarint(data, offset: offset)
            return newOffset
        case 1: // 64-bit
            return offset + 8
        case 2: // Length-delimited
            let (_, newOffset) = readLengthDelimited(data, offset: offset)
            return newOffset
        case 5: // 32-bit
            return offset + 4
        default:
            return -1 // Unknown wire type
        }
    }
}

// MARK: - Bitrate Selection

public extension SPClient.TrackMetadata {
    /// Select best available file for given quality preference
    /// Prefers OGG Vorbis, but falls back to MP3 if needed
    nonisolated func selectFile(preferredQuality: AudioFormat = .oggVorbis320, allowMP3: Bool = true) -> AudioFile? {
        // Filter to OGG Vorbis formats (preferred)
        let vorbisFiles = files.filter {
            switch $0.format {
            case .oggVorbis96, .oggVorbis160, .oggVorbis320:
                true
            default:
                false
            }
        }

        // Sort by quality (descending)
        let sortedVorbis = vorbisFiles.sorted { $0.format.qualityRank > $1.format.qualityRank }

        // Find preferred or next best Vorbis
        if let preferred = sortedVorbis.first(where: { $0.format.qualityRank <= preferredQuality.qualityRank }) {
            return preferred
        }
        if let best = sortedVorbis.first {
            return best
        }

        // Fall back to MP3 if allowed (AudioToolbox can decode MP3)
        if allowMP3 {
            let mp3Files = files.filter {
                switch $0.format {
                case .mp3320, .mp3256, .mp3160, .mp3160Enc, .mp3096:
                    true
                default:
                    false
                }
            }
            let sortedMP3 = mp3Files.sorted { $0.format.qualityRank > $1.format.qualityRank }
            return sortedMP3.first
        }

        return nil
    }

    /// Check if the file format is MP3
    nonisolated static func isMP3Format(_ format: AudioFormat) -> Bool {
        switch format {
        case .mp3320, .mp3256, .mp3160, .mp3160Enc, .mp3096:
            true
        default:
            false
        }
    }

    /// Check if the file format is OGG Vorbis
    nonisolated static func isVorbisFormat(_ format: AudioFormat) -> Bool {
        switch format {
        case .oggVorbis96, .oggVorbis160, .oggVorbis320:
            true
        default:
            false
        }
    }
}
