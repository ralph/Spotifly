//
//  AccesspointConnectTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// A refused connect fails at once, not at the connect deadline, so the
/// session can move on to the next accesspoint.
struct AccesspointConnectTests {
    @Test func `a refused connect fails at once`() async {
        // Nothing listens on port 1 of the loopback interface, so a connect
        // there is answered with a reset, as a refusing accesspoint answers it.
        let accesspoint = Accesspoint(endpoint: "127.0.0.1:1")
        let started = ContinuousClock.now

        let error = await #expect(throws: LibrespotError.self) {
            try await accesspoint.connect(credentials: .accessToken("token", username: "user"), deviceId: "device")
        }
        await accesspoint.disconnect()

        guard case .connectionFailed = error else {
            Issue.record("Expected connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
