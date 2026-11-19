//
//  WireFormatPinTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// The exact bytes the one outgoing message, the PutState, is serialized to.
///
/// The expected value was recorded from the hand-written serializer on 2026-09-26, while it
/// was live-verified against Spotify: connect-state answered the PutState with 200. It pins
/// that behaviour so the message can be re-expressed without changing a byte.
@MainActor
struct WireFormatPinTests {
    /// Recorded output, keyed by the message it came from.
    private static let pinned: [String: String] = [
        "putState-registration": "129a010a9701080110ffff011a0853706f7469666c79223d10012801380140404a0b617564696f2f747261636b4a0d617564696f2f657069736f646550017801800101880101900101980101a00101b80101c801013205312e302e3038014a05332e322e3652086465766963652d316a20363562373038303733666330343830656139326130373732333363613837626472054170706c657a034d6163180228016080d8c1a28c34",
    ]

    private static func check(_ name: String, _ data: Data) {
        #expect(data.hexString == pinned[name], "\(name) changed on the wire")
    }

    @Test func `the registration serializes to its recorded bytes`() {
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
