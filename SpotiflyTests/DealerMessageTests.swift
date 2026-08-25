//
//  DealerMessageTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// The wire shape of a dealer websocket message.
///
/// Taken from librespot's `WebsocketMessage` / `WebsocketRequest`
/// (`core/src/dealer/protocol.rs`), which is the deserializer these messages
/// are actually written for. The distinction that matters: a **message**
/// carries `payloads`, an array whose elements are bare base64 strings, while
/// a **request** carries a single `payload` *object* with a `compressed` key.
/// Modelling the first like the second means every cluster push is dropped.
struct DealerMessageTests {
    private func decode(_ json: String) throws -> DealerMessage {
        try JSONDecoder().decode(DealerMessage.self, from: Data(json.utf8))
    }

    @Test func `a cluster push carries its payload as a bare base64 string`() throws {
        let payload = Data("cluster-protobuf-bytes".utf8)
        let json = """
        {
          "type": "message",
          "uri": "hm://connect-state/v1/cluster",
          "headers": {},
          "payloads": ["\(payload.base64EncodedString())"]
        }
        """

        let message = try decode(json)

        #expect(message.uri == "hm://connect-state/v1/cluster")
        #expect(DealerConnection.payloadData(from: message, headers: message.headers) == payload)
    }

    /// The gzip variant, which is how the large pushes actually arrive.
    ///
    /// The fixture is a real gzip stream rather than one this app produced —
    /// `printf 'cluster-protobuf-bytes' | gzip -n | base64` — so it exercises
    /// inflating what Spotify sends rather than round-tripping our own
    /// compressor and agreeing with ourselves.
    @Test func `a gzipped payload is inflated`() throws {
        let json = """
        {
          "type": "message",
          "uri": "hm://connect-state/v1/cluster",
          "headers": {"Transfer-Encoding": "gzip"},
          "payloads": ["H4sIAAAAAAAAA0vOKS0uSS3SLSjKL8lPKk3TTaosSS0GAJFcKGcWAAAA"]
        }
        """

        let message = try decode(json)

        #expect(
            DealerConnection.payloadData(from: message, headers: message.headers)
                == Data("cluster-protobuf-bytes".utf8),
        )
    }

    /// librespot accepts a raw byte array here too, so neither form may throw.
    @Test func `a payload sent as a byte array is accepted`() throws {
        let json = """
        {
          "type": "message",
          "uri": "hm://connect-state/v1/cluster",
          "headers": {},
          "payloads": [[104, 105]]
        }
        """

        let message = try decode(json)

        #expect(DealerConnection.payloadData(from: message, headers: message.headers) == Data("hi".utf8))
    }

    /// A message with no payloads at all must still decode — plenty arrive that
    /// way, and dropping them took the routing for every other URI with it.
    @Test func `a message without payloads still decodes`() throws {
        let json = """
        {"type": "message", "uri": "hm://some/other/topic", "headers": {}}
        """

        let message = try decode(json)

        #expect(message.uri == "hm://some/other/topic")
        #expect(DealerConnection.payloadData(from: message, headers: message.headers) == nil)
    }

    /// Requests keep their own shape: one object, under `payload.compressed`.
    /// Fixture from `printf '{"message_id":7}' | gzip -n | base64`.
    @Test func `a request keeps its compressed payload object`() throws {
        let json = """
        {
          "type": "request",
          "key": "abc",
          "message_ident": "hm://connect-state/v1/player/command",
          "headers": {"Transfer-Encoding": "gzip"},
          "payload": {"compressed": "H4sIAAAAAAAAA6tWyk0tLk5MT43PTFGyMq8FAMw8JsAQAAAA"}
        }
        """

        let message = try decode(json)

        #expect(message.type == "request")
        #expect(
            DealerConnection.decodeCompressedPayload(message.payloadCompressed)
                == Data(#"{"message_id":7}"#.utf8),
        )
    }
}
