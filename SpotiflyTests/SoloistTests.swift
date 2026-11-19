//
//  SoloistTests.swift
//  SpotiflyTests
//
//  Spotify's Soloist as this Mac's player: its build, its socket, and where plays go
//

import Foundation
@testable import Spotifly
import Testing

struct SoloistBuildTests {
    /// What Soloist 1.3.10.37 printed for `--version` on 2026-11-07.
    @Test func `the version and build date are read from --version`() throws {
        let build = try #require(SoloistInstaller.parse(
            version: "soloist 1.3.10.37 build 1793685705 (20261103) (g19412df6ea) (macos/aarch64)\n",
        ))

        #expect(build.version == "1.3.10.37")
        #expect(build.built == Date(timeIntervalSince1970: 1_793_685_705))
    }

    @Test func `anything else is not a version`() {
        #expect(SoloistInstaller.parse(version: "") == nil)
        #expect(SoloistInstaller.parse(version: "soloist 1.3.10.37") == nil)
        #expect(SoloistInstaller.parse(version: "librespot 0.6.0 build 1793685705") == nil)
    }

    /// A build stops starting 90 days after it was built, and is renewed in its last 30.
    @Test func `a build is renewed in its last 30 days and unusable after 90`() {
        let built = Date(timeIntervalSince1970: 1_793_685_705)
        let build = SoloistBuild(version: "1.3.10.37", built: built)
        let day: TimeInterval = 86400

        #expect(build.isUsable(at: built.addingTimeInterval(59 * day)))
        #expect(!build.isDue(at: built.addingTimeInterval(59 * day)))
        #expect(build.isDue(at: built.addingTimeInterval(60 * day)))
        #expect(build.isUsable(at: built.addingTimeInterval(89 * day)))
        #expect(!build.isUsable(at: built.addingTimeInterval(90 * day)))
    }

    @Test func `a binary not signed by Spotify is not run`() async {
        #expect(await !SoloistInstaller.isSpotifys(URL(filePath: "/bin/ls")))
        #expect(await !SoloistInstaller.isSpotifys(URL(filePath: "/nonexistent/soloist")))
    }
}

struct SoloistEventTests {
    private func event(_ json: String) throws -> SoloistEvent {
        try JSONDecoder().decode(SoloistEvent.self, from: Data(json.utf8))
    }

    /// Messages `soloist ctl trace` recorded from Soloist 1.3.10.37 on 2026-11-09.
    @Test func `pairing is read from the socket`() throws {
        let waiting = try event(
            #"{"type":"auth_state","logged_in":false,"is_active":false,"device_name":"Spotifly Soloist Test"}"#,
        )
        let active = try event(#"{"type":"device_changed","is_active":true,"device_name":"Spotifly Soloist Test"}"#)

        #expect(waiting == SoloistEvent(loggedIn: false))
        #expect(active == SoloistEvent(loggedIn: nil))
    }

    @MainActor
    @Test func `the engine is ready once Soloist is paired`() {
        let engine = SoloistEngine.shared
        engine.apply(SoloistEvent(loggedIn: false))
        #expect(engine.status == .waitingForPairing)

        engine.apply(SoloistEvent(loggedIn: nil))
        #expect(engine.status == .waitingForPairing)

        engine.apply(SoloistEvent(loggedIn: true))
        #expect(engine.status == .ready)
    }
}

@MainActor
struct SoloistTargetTests {
    /// Soloist plays for this Mac, so it takes a play even while a phone plays.
    @Test func `a ready Soloist is where plays go`() {
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: "phone", soloist: .ready(deviceId: "soloist"))
            == .remote(deviceId: "soloist"))
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: nil, soloist: .ready(deviceId: "soloist"))
            == .remote(deviceId: "soloist"))
    }

    /// Set up but not ready, with nothing else to play on, says so.
    @Test func `a Soloist that is not ready is said to be`() {
        #expect(PlaybackViewModel.playbackTarget(activeDeviceId: nil, soloist: .notReady) == .soloistNotReady)
    }
}
