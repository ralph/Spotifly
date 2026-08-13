//
//  ClientTokenTests.swift
//  SpotiflyTests
//
//  The Client-Token handshake, and the protobuf primitives underneath it.
//

import Foundation
@testable import Spotifly
import Testing

/// The wire format, checked against bytes rather than against itself.
struct ProtobufWireFormatTests {
    @Test func `a varint field encodes as tag then value`() {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 1)
        // field 1, wire type 0 -> 0x08; value 1.
        #expect(Array(writer.data) == [0x08, 0x01])
    }

    @Test func `values of 128 and up continue into a second byte`() {
        var writer = ProtobufWriter()
        writer.varint(field: 2, 300)
        // field 2, wire type 0 -> 0x10; 300 -> 0xAC 0x02.
        #expect(Array(writer.data) == [0x10, 0xAC, 0x02])
    }

    @Test func `a string field is length-prefixed utf8`() {
        var writer = ProtobufWriter()
        writer.string(field: 2, "hi")
        // field 2, wire type 2 -> 0x12; length 2; "hi".
        #expect(Array(writer.data) == [0x12, 0x02, 0x68, 0x69])
    }

    @Test func `a nested message is written as length-prefixed bytes`() {
        var writer = ProtobufWriter()
        writer.message(field: 1) { nested in
            nested.varint(field: 1, 1)
        }
        #expect(Array(writer.data) == [0x0A, 0x02, 0x08, 0x01])
    }

    @Test func `an empty submessage still occupies its field`() {
        // The macOS platform data is sent empty, and Spotify expects the field to be present.
        var writer = ProtobufWriter()
        writer.message(field: 3) { _ in }
        #expect(Array(writer.data) == [0x1A, 0x00])
    }

    @Test func `the reader recovers what the writer wrote`() {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 42)
        writer.string(field: 2, "token")

        #expect(ProtobufReader.firstVarint(field: 1, in: writer.data) == 42)
        #expect(ProtobufReader.firstString(field: 2, in: writer.data) == "token")
    }

    @Test func `unknown fields are skipped rather than failing the read`() {
        // Spotify adds fields to these messages without warning; a reader that rejected them
        // would break on a server change that costs us nothing.
        var writer = ProtobufWriter()
        writer.string(field: 7, "something new")
        writer.varint(field: 1, 9)

        #expect(ProtobufReader.firstVarint(field: 1, in: writer.data) == 9)
    }

    @Test func `a truncated message reads as finished, not as a crash`() {
        var writer = ProtobufWriter()
        writer.string(field: 1, "abcdef")
        let truncated = writer.data.prefix(3)

        #expect(ProtobufReader.firstString(field: 1, in: Data(truncated)) == nil)
    }
}

/// The request Spotify is sent, and the response it sends back.
struct ClientTokenRequestTests {
    private let deviceId = "0123456789abcdef0123456789abcdef01234567"

    @Test func `the request carries the client id and device id where Spotify expects them`() throws {
        let encoded = ClientTokenRequest.encode(clientId: "the-client-id", deviceId: deviceId)

        #expect(ProtobufReader.firstVarint(field: 1, in: encoded) == 1)

        let clientData = try #require(ProtobufReader.firstBytes(field: 2, in: encoded))
        #expect(ProtobufReader.firstString(field: 1, in: clientData) == "0.0.0")
        #expect(ProtobufReader.firstString(field: 2, in: clientData) == "the-client-id")

        let sdkData = try #require(ProtobufReader.firstBytes(field: 3, in: clientData))
        #expect(ProtobufReader.firstString(field: 2, in: sdkData) == deviceId)

        // platform_specific_data { mac {} } — present, and empty.
        let platform = try #require(ProtobufReader.firstBytes(field: 1, in: sdkData))
        let mac = try #require(ProtobufReader.firstBytes(field: 3, in: platform))
        #expect(mac.isEmpty)
    }

    private func grantedResponse(token: String, expiresAfter: UInt64?) -> Data {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 1)
        writer.message(field: 2) { granted in
            granted.string(field: 1, token)
            if let expiresAfter {
                granted.varint(field: 2, expiresAfter)
            }
        }
        return writer.data
    }

    @Test func `a granted token is read with its expiry`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let granted = try ClientTokenRequest.decode(
            grantedResponse(token: "ct-1", expiresAfter: 1_209_600),
            now: now,
        )

        #expect(granted.token == "ct-1")
        #expect(granted.expiresAt == now.addingTimeInterval(1_209_600))
    }

    @Test func `a response without an expiry gets an hour, not forever`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let granted = try ClientTokenRequest.decode(grantedResponse(token: "ct-1", expiresAfter: nil), now: now)

        #expect(granted.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func `a challenge is reported rather than mistaken for a token`() {
        var writer = ProtobufWriter()
        writer.varint(field: 1, 2)
        writer.message(field: 3) { $0.string(field: 1, "state") }

        #expect(throws: ClientTokenError.self) {
            try ClientTokenRequest.decode(writer.data)
        }
    }

    @Test func `an empty token is not a token`() {
        #expect(throws: ClientTokenError.self) {
            try ClientTokenRequest.decode(grantedResponse(token: "", expiresAfter: 60))
        }
    }

    @Test func `an unreadable response is an error, not an empty token`() {
        #expect(throws: ClientTokenError.self) {
            try ClientTokenRequest.decode(Data([0xFF, 0xFF]))
        }
    }
}

private struct FixedDeviceIdStore: DeviceIdStoring {
    let id: String
    func deviceId() -> String {
        id
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private var round = 0

    func fetch(expiresAt: Date) -> GrantedClientToken {
        lock.withLock {
            calls += 1
            round += 1
            return GrantedClientToken(token: "ct-\(round)", expiresAt: expiresAt)
        }
    }
}

struct ClientTokenProviderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let store = FixedDeviceIdStore(id: "0123456789abcdef0123456789abcdef01234567")

    @Test func `a cached token is reused until it expires`() async throws {
        let counter = FetchCounter()
        let expiry = now.addingTimeInterval(3600)
        let provider = ClientTokenProvider(deviceIdStore: store, fetcher: { _ in counter.fetch(expiresAt: expiry) })

        #expect(try await provider.token(now: now) == "ct-1")
        #expect(try await provider.token(now: now.addingTimeInterval(60)) == "ct-1")
        #expect(counter.calls == 1)
    }

    @Test func `an expired token is replaced`() async throws {
        let counter = FetchCounter()
        let provider = ClientTokenProvider(
            deviceIdStore: store,
            fetcher: { _ in counter.fetch(expiresAt: Date(timeIntervalSince1970: 1_000_100)) },
        )

        #expect(try await provider.token(now: now) == "ct-1")
        #expect(try await provider.token(now: Date(timeIntervalSince1970: 1_000_200)) == "ct-2")
        #expect(counter.calls == 2)
    }

    @Test func `invalidating forces a fresh token even though the old one had time left`() async throws {
        // What a 401 means: the token is dead before its stated expiry.
        let counter = FetchCounter()
        let expiry = now.addingTimeInterval(3600)
        let provider = ClientTokenProvider(deviceIdStore: store, fetcher: { _ in counter.fetch(expiresAt: expiry) })

        #expect(try await provider.token(now: now) == "ct-1")
        await provider.invalidate()
        #expect(try await provider.token(now: now) == "ct-2")
    }

    @Test func `concurrent callers share one fetch`() async throws {
        let counter = FetchCounter()
        let expiry = now.addingTimeInterval(3600)
        let provider = ClientTokenProvider(deviceIdStore: store, fetcher: { _ in counter.fetch(expiresAt: expiry) })
        let asOf = now

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await provider.token(now: asOf) }
            }
            var collected: [String] = []
            for try await token in group {
                collected.append(token)
            }
            return collected
        }

        #expect(tokens.allSatisfy { $0 == "ct-1" })
        #expect(counter.calls == 1)
    }

    @Test func `the device id is 40 hex characters, as the desktop client sends`() {
        let generated = UserDefaultsDeviceIdStore.generate()

        #expect(generated.count == 40)
        #expect(generated.allSatisfy(\.isHexDigit))
        #expect(generated != UserDefaultsDeviceIdStore.generate())
    }
}
