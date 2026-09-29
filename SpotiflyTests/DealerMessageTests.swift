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
        // Routed by `message_ident`: requests have no `uri`.
        #expect(message.uri == "hm://connect-state/v1/player/command")
        #expect(
            DealerConnection.decodeCompressedPayload(message.payloadCompressed)
                == Data(#"{"message_id":7}"#.utf8),
        )
    }
}

/// Volume set on another device, which arrives as a `SetVolumeCommand` protobuf.
struct VolumeCommandTests {
    /// Logged by this app on 2026-09-27 as Spotify's web player set it to about 60%:
    /// `1: volume` (38757), `2: command_options { 1: message_id }`, and the sending device's
    /// id in field 5.
    @Test func `the volume is read from a real SetVolumeCommand`() throws {
        let hex = "08e5ae02120608d8e5bd8b062a2837393733306335626462313236323537313034643737316364653130363464323432313961396633"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            try bytes.append(#require(UInt8(hex[index ..< next], radix: 16)))
            index = next
        }

        #expect(DealerConnection.volume(inSetVolumeCommand: Data(bytes)) == 38757)
    }

    @Test func `a JSON body is not mistaken for a volume`() {
        #expect(DealerConnection.volume(inSetVolumeCommand: Data(#"{"volume":19731}"#.utf8)) == nil)
    }
}

/// Shuffle and repeat as Spotify's web player sends them: one `set_options` endpoint.
struct SetOptionsCommandTests {
    /// The `command` objects of the web player's own requests, captured from its page on
    /// 2026-09-27 while it controlled this app: the shuffle button, then the repeat button.
    private static let capturedShuffle = #"""
    {"shuffling_context":true,"modes":{"context_enhancement":"NONE"},"logging_params":{"page_instance_ids":["b577dccf-3300-4168-b835-505221756720"],"interaction_ids":["f139a8af-ef24-41e2-8ea6-65e0706c8401"],"command_id":"5a0cb69e32d038a8b2d74973994ea893"},"endpoint":"set_options"}
    """#
    private static let capturedRepeat = #"""
    {"repeating_context":true,"repeating_track":false,"endpoint":"set_options","logging_params":{"command_id":"421374f94414a93c3f883980d02b44e3"}}
    """#

    private static func parse(_ json: String) throws -> SpircCommand {
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return DealerConnection.parseCommand(endpoint: object["endpoint"] as? String ?? "", json: object)
    }

    @Test func `the shuffle button sets only shuffle`() throws {
        guard case let .setOptions(shuffle, repeatContext, repeatTrack) = try Self.parse(Self.capturedShuffle) else {
            Issue.record("not read as set_options")
            return
        }
        #expect(shuffle == true)
        #expect(repeatContext == nil)
        #expect(repeatTrack == nil)
    }

    @Test func `the repeat button sets only repeat`() throws {
        guard case let .setOptions(shuffle, repeatContext, repeatTrack) = try Self.parse(Self.capturedRepeat) else {
            Issue.record("not read as set_options")
            return
        }
        #expect(shuffle == nil)
        #expect(repeatContext == true)
        #expect(repeatTrack == false)
    }
}

/// Queue edits as other devices send them, captured on 2026-09-27 while this app played
/// "Not Bad for New Jersey" with a track and then the same album queued: the iPhone app
/// removing and moving queued tracks, and the web player sending the queue back as it was.
/// The fixtures leave out `logging_params`, which names the sending device.
struct SetQueueCommandTests {
    private static func queued(_ fixture: String) throws -> [String] {
        let object = try #require(JSONSerialization.jsonObject(with: fixtureData(fixture)) as? [String: Any])
        guard case let .setQueue(uris) = DealerConnection.parseCommand(endpoint: object["endpoint"] as? String ?? "", json: object) else {
            Issue.record("not read as set_queue")
            return []
        }
        return uris.map { $0.replacingOccurrences(of: "spotify:track:", with: "") }
    }

    /// The album's tracks after the first, as queued.
    private static let albumRest = [
        "4dXrwm7f6Hrpyk6MTvBO98", "3fHhIJkGYR4QKy1LvjXUOK", "7aEd4015g5QiEVNCEgstMS",
        "48EGw6eq8yJxNYWZ6M4Kck", "3hQDsAxTyB6IZa7ZXgV4HD", "28BisapD9huxRmUAxYs0qD",
        "12Vu0bL0e0ljFaI3VTYp4A", "335IQurCbCu8aXABK69b42", "1fjCCMPyDcHf6Iw3gQNEQJ",
        "1kEzkpxMYuqc8AiAbg6XNB",
    ]
    private static let albumFirst = "2J1gYYXbLb3JJWjbOS6DJO"
    private static let betterBefore = "4dXrwm7f6Hrpyk6MTvBO98"
    private static let pearls = "3fHhIJkGYR4QKy1LvjXUOK"
    private static let onGoodTerms = "48EGw6eq8yJxNYWZ6M4Kck"

    /// The context tracks that follow carry the same album's tracks: taking them too
    /// would queue each one twice.
    @Test func `the queue section ends at the first context track`() throws {
        #expect(try Self.queued("set-queue-web-player-unchanged") == ["0Y9muyQw5qQ6l7ZMEkkUNG", Self.albumFirst] + Self.albumRest)
    }

    @Test func `a track removed on the phone is left out`() throws {
        #expect(try Self.queued("set-queue-iphone-removed") == [Self.albumFirst] + Self.albumRest.filter { $0 != Self.betterBefore })
    }

    /// The moved track arrives without a provider; it is still in the queue section.
    @Test func `a track moved to the top of the queue leads it`() throws {
        #expect(try Self.queued("set-queue-iphone-moved-to-top") == [Self.pearls, Self.albumFirst] + Self.albumRest.filter { $0 != Self.pearls })
    }

    @Test func `a track moved within the queue takes its new place`() throws {
        let rest = Self.albumRest.filter { $0 != Self.onGoodTerms }
        #expect(try Self.queued("set-queue-iphone-moved-within") == [Self.albumFirst, rest[0], Self.onGoodTerms] + rest.dropFirst())
    }

    @Test func `a set_queue without its list does not empty the queue`() {
        guard case .unknown = DealerConnection.parseCommand(endpoint: "set_queue", json: ["endpoint": "set_queue"]) else {
            Issue.record("read as a queue")
            return
        }
    }
}

/// Remote `play` commands, in the shapes Spotify's clients send them.
struct PlayCommandTests {
    private static func play(_ json: String) throws -> SpircCommand.PlayCommand {
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try play(object)
    }

    private static func play(_ object: [String: Any]) throws -> SpircCommand.PlayCommand {
        guard case let .play(command) = DealerConnection.parseCommand(endpoint: "play", json: object) else {
            throw CocoaError(.coderInvalidValue)
        }
        return command
    }

    /// The iPhone app starting a playlist, from a librespot log of 2026-01-16: the uri, and the
    /// first page of tracks beside it. The page is only a window, so the uri is resolved.
    @Test func `a playlist from the iPhone is resolved by its uri, not read from its page`() throws {
        let command = try Self.play(#"""
        {"endpoint":"play","context":{"uri":"spotify:playlist:4fRJrzSdP27aXlZ1mmew7a","url":"context://spotify:playlist:4fRJrzSdP27aXlZ1mmew7a","pages":[{"tracks":[{"uid":"b91b61a0642fc20b","uri":"spotify:track:7FwBtcecmlpc1sLySPXeGE"},{"uid":"af892e84ccd0ff86","uri":"spotify:track:6VojZJpMyuKClbwyilWlQj"}]}]},"options":{"skip_to":{}}}
        """#)

        #expect(command.contextUri == "spotify:playlist:4fRJrzSdP27aXlZ1mmew7a")
        #expect(command.trackUris == nil)
        #expect(command.trackUri == nil)
        #expect(command.index == nil)
    }

    @Test func `a row clicked in an album names its track and its index`() throws {
        let command = try Self.play(#"""
        {"endpoint":"play","context":{"uri":"spotify:album:a1","url":"context://spotify:album:a1"},"options":{"skip_to":{"track_uri":"spotify:track:t4","track_uid":"u4","track_index":3,"page_index":0},"seek_to":1500}}
        """#)

        #expect(command.contextUri == "spotify:album:a1")
        #expect(command.trackUri == "spotify:track:t4")
        #expect(command.index == 3)
        #expect(command.positionMs == 1500)
    }

    /// librespot's `PlayContext::Tracks`: a context with no uri carries its tracks inline, which
    /// is how a Web API `uris` play arrives. The command was read as having nothing to play.
    @Test func `a context with no uri plays the tracks it carries, from the one it names`() throws {
        let command = try Self.play(#"""
        {"endpoint":"play","context":{"pages":[{"tracks":[{"uri":"spotify:track:t1"},{"uri":"spotify:track:t2"}]},{"tracks":[{"uri":"spotify:track:t3"}]}]},"options":{"skip_to":{"track_index":2}}}
        """#)

        #expect(command.contextUri == nil)
        #expect(command.trackUris == ["spotify:track:t1", "spotify:track:t2", "spotify:track:t3"])
        #expect(command.index == 2)
    }

    /// The web player's own empty context is `uri: ""`, `url: ""`.
    @Test func `an empty context uri is no uri`() throws {
        let command = try Self.play(#"""
        {"endpoint":"play","context":{"uri":"","url":"","pages":[{"tracks":[{"uri":"spotify:track:t1"},{"uri":"spotify:track:t2"}]}]}}
        """#)

        #expect(command.contextUri == nil)
        #expect(command.trackUris == ["spotify:track:t1", "spotify:track:t2"])
    }

    /// Search's Play All on another device is this command, so one Spotifly can play a list on
    /// another.
    @Test func `the bare list this app sends is read back as that list`() throws {
        let data = try JSONEncoder().encode(ConnectCommandEnvelope(.play(trackUris: ["spotify:track:t1", "spotify:track:t2"])))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try Self.play(#require(body["command"] as? [String: Any]))

        #expect(command.contextUri == nil)
        #expect(command.trackUris == ["spotify:track:t1", "spotify:track:t2"])
    }

    @Test func `a single track is a context of its own`() throws {
        let command = try Self.play(#"""
        {"endpoint":"play","context":{"uri":"spotify:track:t1","url":"context://spotify:track:t1"},"options":{"skip_to":{"track_uri":"spotify:track:t1"}}}
        """#)

        #expect(command.contextUri == "spotify:track:t1")
        #expect(command.trackUris == nil)
    }
}
