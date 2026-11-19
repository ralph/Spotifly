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
    /// The topic: a message's `uri`, or a request's `message_ident`.
    public let uri: String?
    public let headers: [String: String]?
    public let payloads: [DealerPayload]?
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
        case messageIdent = "message_ident"
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        // A request names its topic in `message_ident` (librespot's
        // `WebsocketRequest`), not `uri`. Reading only `uri` routed no request
        // anywhere: a cluster update sent as one was acknowledged as handled
        // and then dropped.
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
            ?? container.decodeIfPresent(String.self, forKey: .messageIdent)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        payloads = try container.decodeIfPresent([DealerPayload].self, forKey: .payloads)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }
}

/// One element of a message's `payloads` array.
///
/// **It is a bare value, not an object.** librespot's `MessagePayloadValue`
/// (`core/src/dealer/protocol.rs`) is an untagged enum of `String` — base64,
/// the form everything here actually arrives in — or a raw byte array, or
/// arbitrary JSON. Modelling it as `{"payload": "…"}` made every
/// payload-carrying message throw on decode, which silently took *all* cluster
/// pushes with it: the device list never updated, and the playback shown never
/// moved on.
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
