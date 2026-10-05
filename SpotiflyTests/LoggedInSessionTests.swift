//
//  LoggedInSessionTests.swift
//  SpotiflyTests
//
//  The signed-in account's store and services belong to the app, not to a window.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct LoggedInSessionTests {
    /// Starting again, as a grant renewed while signed in does, keeps the session, so the store
    /// and services playback and the menus use stay the ones the windows show.
    @Test func `starting again keeps the one session`() {
        let sessions = LoggedInSessions()

        #expect(sessions.start() === sessions.start())
    }

    /// The next account starts from an empty store.
    @Test func `signing out ends the session`() {
        let sessions = LoggedInSessions()
        let first = sessions.start()

        sessions.end()

        #expect(sessions.current == nil)
        #expect(sessions.start() !== first)
    }

    /// Nothing outside the session holds it: playback keeps it weakly, and the queue service's
    /// observations, started with it, hold the store only until the service's `deinit` cancels
    /// them, and a cancelled observation ends.
    @Test func `an ended session is freed`() async throws {
        let sessions = LoggedInSessions()
        weak let store = sessions.start().store
        await settle()

        sessions.end()

        try await waitUntil { store == nil }
    }
}
