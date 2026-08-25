//
//  DealerMessage.swift
//  SwiftLibrespot
//
//  JSON message types for the Spotify dealer WebSocket
//

@preconcurrency import Foundation

// MARK: - Incoming Messages

/// Wrapper for dealer messages
public nonisolated struct DealerMessage: Sendable, Decodable {
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

extension DealerMessage {
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

/// One element of a message's `payloads` array.
///
/// **It is a bare value, not an object.** librespot's `MessagePayloadValue`
/// (`core/src/dealer/protocol.rs`) is an untagged enum of `String` — base64,
/// the form everything here actually arrives in — or a raw byte array, or
/// arbitrary JSON. Modelling it as `{"payload": "…"}` made every
/// payload-carrying message throw on decode, which silently took *all* cluster
/// pushes, remote commands and volume commands with it: the device list never
/// updated, and this device never learned it had stopped being the active one.
public nonisolated struct DealerPayload: Sendable, Decodable {
    /// The payload's bytes, however the message spelled them, still base64- and
    /// gzip-undone by the caller (`DealerConnection.payloadData`).
    public let decodedData: Data?
}

public extension DealerPayload {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let base64 = try? container.decode(String.self) {
            decodedData = Data(base64Encoded: base64)
        } else if let bytes = try? container.decode([UInt8].self) {
            decodedData = Data(bytes)
        } else {
            // librespot's third variant is arbitrary JSON, which none of the
            // URIs routed here send. Decoding to nil rather than throwing keeps
            // the surrounding message intact so it still reaches its handler.
            decodedData = nil
        }
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
