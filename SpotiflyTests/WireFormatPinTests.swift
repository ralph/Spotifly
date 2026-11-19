//
//  WireFormatPinTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// The exact bytes every outgoing message is serialized to.
///
/// The expected values were recorded from the hand-written serializers on 2026-09-26,
/// while those were live-verified against Spotify: the accesspoint accepted the handshake
/// and login they produce, and connect-state answered their PutState with 200. They pin
/// that behaviour so the messages can be re-expressed without changing a byte — a
/// handshake HMAC covers the ClientHello, so even a reordering fails the login.
@MainActor
struct WireFormatPinTests {
    /// Recorded output, keyed by the message it came from.
    private static let pinned: [String: String] = [
        "clientHello": "520e5000a00100f00101c002e2ca9c3bf0010092036752655260111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111a00101e2031022222222222222222222222222222222b204011e",
        "clientResponsePlaintext": "5218521652143333333333333333333333333333333333333333a20100f20100",
        "login-stored": "52125207736f6d656f6e65a00101f201030102039203225005e00302d2050f6c6962726573706f7420302e382e30a206086465766963652d31b2040f6c6962726573706f7420302e382e30",
        "login-token": "52145207736f6d656f6e65a00103f20105746f6b656e9203225005e00302d2050f6c6962726573706f7420302e382e30a206086465766963652d31b2040f6c6962726573706f7420302e382e30",
        "putState-registration": "129a010a9701080110ffff011a0853706f7469666c79223d10012801380140404a0b617564696f2f747261636b4a0d617564696f2f657069736f646550017801800101880101900101980101a00101b80101c801013205312e302e3038014a05332e322e3652086465766963652d316a20363562373038303733666330343830656139326130373732333363613837626472054170706c657a034d6163180228016080d8c1a28c34",
    ]

    private static func check(_ name: String, _ data: Data) {
        #expect(data.hexString == pinned[name], "\(name) changed on the wire")
    }

    @Test func `every outgoing message serializes to its recorded bytes`() {
        let clientHello = KeyExchange.clientHello(
            publicKey: Data(repeating: 0x11, count: 96),
            nonce: Data(repeating: 0x22, count: 16),
            platform: .osxX86,
            version: 124_200_290,
        )
        Self.check("clientHello", clientHello)

        Self.check("clientResponsePlaintext", KeyExchange.clientResponsePlaintext(hmac: Data(repeating: 0x33, count: 20)))

        for (name, authType, authData) in [
            ("stored", AuthenticationType.storedSpotifyCredentials, Data([1, 2, 3])),
            ("token", .spotifyToken, Data("token".utf8)),
        ] {
            let login = Authentication.clientResponseEncrypted(
                username: "someone",
                authType: authType,
                authData: authData,
                cpuFamily: .arm,
                os: .osx,
                deviceId: "device-1",
                version: "librespot 0.8.0",
            )
            Self.check("login-\(name)", login)
        }

        var device = ConnectDevice()
        device.deviceInfo.canPlay = true
        device.deviceInfo.volume = 32767
        device.deviceInfo.name = "Spotifly"
        device.deviceInfo.deviceId = "device-1"
        device.deviceInfo.deviceType = .computer
        device.deviceInfo.deviceSoftwareVersion = "1.0.0"
        device.deviceInfo.clientId = "65b708073fc0480ea92a077233ca87bd"
        device.deviceInfo.brand = "Apple"
        device.deviceInfo.model = "Mac"
        var caps = ConnectCapabilities()
        caps.canBePlayer = true
        caps.isObservable = true
        caps.volumeSteps = 64
        caps.supportedTypes = ["audio/track", "audio/episode"]
        caps.commandAcks = true
        caps.supportsGzipPushes = true
        caps.supportsTransferCommand = true
        caps.supportsCommandRequest = true
        device.deviceInfo.capabilities = caps

        var registration = PutStateRequestProto()
        registration.device = device
        registration.memberType = .connectState
        registration.isActive = false
        registration.putStateReason = .spircHello
        registration.clientSideTimestamp = 1_790_000_000_000
        Self.check("putState-registration", registration.serialize())
    }
}
