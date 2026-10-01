//
//  AccountTypeTests.swift
//  SpotiflyTests
//
//  The account type the accesspoint names after login, and what it lets this Mac do.
//

import Foundation
@testable import Spotifly
import Testing

struct AccountTypeTests {
    /// What a Premium account got on 2026-09-29, cut to 8 of its 101 elements: the others
    /// describe the plan, its billing and client flags. Declaration, nesting and order are as
    /// received.
    static func productInfo() throws -> Data {
        try fixtureData("product-info-premium", withExtension: "xml")
    }

    @Test func `a Premium account is named premium`() throws {
        #expect(try Accesspoint.accountType(inProductInfo: Self.productInfo()) == "premium")
    }

    @Test func `the same payload edited to free is named free`() throws {
        let free = try String(decoding: Self.productInfo(), as: UTF8.self)
            .replacingOccurrences(of: "<type>premium</type>", with: "<type>free</type>")
        #expect(Accesspoint.accountType(inProductInfo: Data(free.utf8)) == "free")
    }

    @Test func `a payload without a type names none`() {
        let payload = "<?xml version='1.0' encoding='utf-8'?><products><product><ads>0</ads></product></products>"
        #expect(Accesspoint.accountType(inProductInfo: Data(payload.utf8)) == nil)
    }

    @Test func `only Premium plays here, and so does an account whose type never came`() {
        #expect(LibrespotSession.streams(accountType: "premium"))
        #expect(!LibrespotSession.streams(accountType: "free"))
        #expect(LibrespotSession.streams(accountType: nil))
    }

    /// As the web player registers when it cannot play. Measured on 2026-09-29: a device
    /// registered this way got the cluster back, and the cluster did not list it.
    @Test func `a Mac that may not play registers hidden, and not as a player`() async {
        let deviceId = "spotifly_test"
        let controller = SpircController(
            deviceInfo: DeviceInfo(deviceId: deviceId, deviceName: "Spotifly", supportsPlayback: false),
            accesspoint: Accesspoint(endpoint: "127.0.0.1:1"),
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
    @Test func `this Mac takes a play, even while a phone is active`() {
        #expect(PlaybackViewModel.playbackTarget(local: .ready, activeDeviceId: "phone") == .local)
    }

    @Test func `for an account that may not play here, a play goes to the active device`() {
        #expect(PlaybackViewModel.playbackTarget(local: .needsPremium, activeDeviceId: "phone") == .remote(deviceId: "phone"))
    }

    @Test func `for an account that may not play here, with nothing active, the play says Premium`() {
        #expect(PlaybackViewModel.playbackTarget(local: .needsPremium, activeDeviceId: nil) == .needsPremium)
    }

    @Test func `without a session, with nothing active, the play asks for authorization`() {
        #expect(PlaybackViewModel.playbackTarget(local: .needsAuthorization, activeDeviceId: nil) == .needsAuthorization)
    }
}
