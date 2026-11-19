//
//  WireFormatPinTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// The exact bytes the one outgoing message, the PutState, is serialized to.
///
/// The request is the one `SpircController` sends: the hidden device that does not play,
/// built by `buildPutStateRequest`. The expected value was recorded from it on 2026-11-19,
/// so the proto can be trimmed or re-expressed without changing a byte on the wire.
@MainActor
struct WireFormatPinTests {
    /// Recorded output, keyed by the message it came from.
    private static let pinned: [String: String] = [
        "putState-registration": "1298010a950110ffff031a0853706f7469666c79223d2801380140404a0b617564696f2f747261636b4a0d617564696f2f657069736f6465500160017801800101880101900101980101a00101b80101c801013205312e302e3038014a05332e322e3652086465766963652d316a20363562373038303733666330343830656139326130373732333363613837626472054170706c657a034d6163180228016080d8c1a28c34",
    ]

    private static func check(_ name: String, _ data: Data) {
        #expect(data.hexString == pinned[name], "\(name) changed on the wire")
    }

    @Test func `the registration serializes to its recorded bytes`() async {
        let deviceId = "device-1"
        let controller = SpircController(
            deviceInfo: DeviceInfo(deviceId: deviceId, deviceName: "Spotifly"),
            dealerConnection: DealerConnection(endpoint: "127.0.0.1:1", credentials: spotifyCredentials(), spclientHost: "", deviceId: deviceId),
        )
        let registration = await controller.buildPutStateRequest(at: Date(timeIntervalSince1970: 1_790_000_000))
        Self.check("putState-registration", registration.serialize())
    }
}
