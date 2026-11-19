//
//  AccountTypeTests.swift
//  SpotiflyTests
//
//  How this Mac's session registers on Spotify Connect, and where a play goes.
//

import Foundation
@testable import Spotifly
import Testing

struct AccountTypeTests {
    /// As the web player registers when it cannot play: Soloist plays for this Mac. Measured on
    /// 2026-09-29: a device registered this way got the cluster back, and the cluster did not
    /// list it.
    @Test func `this Mac's session registers hidden, and not as a player`() async {
        let deviceId = "spotifly_test"
        let controller = SpircController(
            deviceInfo: DeviceInfo(deviceId: deviceId, deviceName: "Spotifly"),
            dealerConnection: DealerConnection(endpoint: "127.0.0.1:1", credentials: spotifyCredentials(), spclientHost: "", deviceId: deviceId),
        )
        let device = await controller.buildDevice().deviceInfo

        #expect(!device.canPlay)
        #expect(!device.capabilities.canBePlayer)
        #expect(device.capabilities.hidden)
    }
}

@MainActor
struct PlaybackTargetTests {
    /// Until Soloist is ready, the device that plays takes a play, so a phone still plays while
    /// Soloist starts, or before it is set up.
    @Test func `with Soloist not ready, a play goes to the active device`() {
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: "phone", soloist: .notReady) == .remote(deviceId: "phone"))
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: "phone", soloist: .notSetUp) == .remote(deviceId: "phone"))
    }

    @Test func `with nothing active and Soloist not set up, the play asks for Soloist`() {
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: nil, soloist: .notSetUp) == .needsSoloist)
    }
}
