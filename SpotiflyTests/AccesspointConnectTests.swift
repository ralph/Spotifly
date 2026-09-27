//
//  AccesspointConnectTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

/// Connecting to an accesspoint that refuses the connection.
///
/// Network.framework reports a refused connect as `.waiting`, not `.failed`,
/// and on a steady network never tries it again. Port 4070 of Spotify's
/// accesspoints refuses about one connect in eight while port 443 of the same
/// host answers, so a refusal has to move the session on to the next
/// accesspoint at once, not after the connect deadline.
struct AccesspointConnectTests {
    @Test func `a refused connect fails at once`() async {
        // Nothing listens on port 1 of the loopback interface, so a connect
        // there is answered with a reset, as a refusing accesspoint answers it.
        let accesspoint = Accesspoint(endpoint: "127.0.0.1:1")
        let started = ContinuousClock.now

        let error = await #expect(throws: LibrespotError.self) {
            try await accesspoint.connect(credentials: .accessToken("token", username: "user"), deviceId: "device")
        }

        guard case .connectionFailed = error else {
            Issue.record("Expected connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
