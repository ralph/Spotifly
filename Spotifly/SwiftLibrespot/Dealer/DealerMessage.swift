//
//  DealerMessage.swift
//  SwiftLibrespot
//
//  JSON message types for the Spotify dealer WebSocket
//

@preconcurrency import Foundation

// MARK: - Incoming Messages

/// Wrapper for dealer messages
public struct DealerMessage: Sendable {
    public let type: String?
    public let uri: String?
    public let headers: [String: String]?
    public let payloads: [DealerPayload]?
    /// The single compressed payload of a *request*-shaped message:
    /// `{"payload": {"compressed": "<base64 gzip json>"}}`.
    public let payloadCompressed: String?
    public let method: String?
    public let key: String?

    /// Connection info message
    public nonisolated var connectionId: String? {
        guard type == "message",
              uri == "hm://pusher/v1/connections/"
        else { return nil }
        return headers?["Spotify-Connection-Id"]
    }
}

extension DealerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, uri, headers, payloads, method, key
        case payload
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        payloads = try container.decodeIfPresent([DealerPayload].self, forKey: .payloads)

        if let nested = try? container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload) {
            payloadCompressed = try nested.decodeIfPresent(String.self, forKey: .compressed)
        } else {
            payloadCompressed = nil
        }

        method = try container.decodeIfPresent(String.self, forKey: .method)
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }

    private enum PayloadKeys: String, CodingKey {
        case compressed
    }
}

/// Payload wrapper in dealer messages
public struct DealerPayload: Sendable {
    /// Base64-encoded protobuf or JSON payload
    public let payload: String?

    /// Decoded payload data
    public nonisolated var decodedData: Data? {
        guard let payload else { return nil }
        return Data(base64Encoded: payload)
    }
}

extension DealerPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case payload
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
    }
}

// MARK: - SPIRC Commands

/// A command received from another Spotify client, with the identifiers
/// needed to acknowledge it through the next PutState.
public struct SpircRemoteCommand: Sendable {
    public let command: SpircCommand
    public let messageId: UInt32?
    public let sentByDeviceId: String?
}

/// Commands that can be received from other Spotify clients
public enum SpircCommand: Sendable {
    case play(PlayCommand)
    case pause
    case resume
    case seekTo(positionMs: UInt64)
    case next
    case prev
    case setVolume(UInt32)
    case setShuffle(Bool)
    case setRepeat(RepeatMode)
    case transfer(TransferCommand)
    case addToQueue(uri: String)
    case unknown(String)

    public struct PlayCommand: Sendable {
        public let contextUri: String?
        public let trackUri: String?
        public let trackUris: [String]?
        public let index: Int?
        public let positionMs: UInt64?
    }

    public struct TransferCommand: Sendable {
        public let targetDeviceId: String
        public let transferData: Data?
    }

    /// Repeat mode as the wire numbers it.
    public enum RepeatMode: Int, Sendable {
        case off = 0
        case context = 1
        case track = 2
    }
}
