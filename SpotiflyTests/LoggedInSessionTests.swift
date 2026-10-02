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
    /// A window that closes and opens again shows the same session, so the store and services it
    /// leaves behind are still the ones playback and the menus use.
    @Test func `every window shows the one session`() {
        let sessions = LoggedInSessions()

        #expect(sessions.session() === sessions.session())
    }

    /// The next account starts from an empty store.
    @Test func `signing out ends the session`() {
        let sessions = LoggedInSessions()
        let first = sessions.session()

        sessions.end()

        #expect(sessions.current == nil)
        #expect(sessions.session() !== first)
    }

    /// Nothing outside the session holds it: playback keeps it weakly, so ending it frees it.
    @Test func `an ended session is freed`() {
        let sessions = LoggedInSessions()
        weak var store = sessions.session().store

        sessions.end()

        #expect(store == nil)
    }
}
