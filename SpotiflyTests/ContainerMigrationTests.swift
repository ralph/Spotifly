//
//  ContainerMigrationTests.swift
//  SpotiflyTests
//
//  The one-time move out of the App Sandbox container
//

import Foundation
@testable import Spotifly
import Testing

/// Each test builds a container of its own in a temporary directory and migrates it into a
/// defaults suite, so nothing touches the developer's settings or keychain.
///
/// One suite name, emptied before and after each test, so serialized: the test host is not
/// sandboxed, so a suite is a file in the developer's own `~/Library/Preferences`, and
/// `cfprefsd` writes it back even after it is deleted. A name per test left a file per test.
@Suite(.serialized)
struct ContainerMigrationTests {
    private let domain = "SpotiflyTests.ContainerMigration"
    private let container = FileManager.default.temporaryDirectory
        .appending(path: "ContainerMigrationTests-\(UUID().uuidString)/Data")

    private var defaults: UserDefaults {
        UserDefaults(suiteName: domain)!
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let plist = container.appending(path: "Library/Preferences/\(domain).plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0).write(to: plist)
    }

    private var credentialsFile: URL {
        container.appending(path: "Library/Application Support/Spotifly/credentials.json")
    }

    private func writeCredentials(_ data: Data) throws {
        try FileManager.default.createDirectory(at: credentialsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: credentialsFile)
    }

    private func migrate(saveLogin: (StoredLogin) throws -> Void = { _ in }) {
        ContainerMigration.runOnce(defaults: defaults, domain: domain, container: container, saveLogin: saveLogin)
    }

    init() {
        UserDefaults(suiteName: domain)!.removePersistentDomain(forName: domain)
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: container.deletingLastPathComponent())
    }

    /// What a test run or a Debug run wrote here first, such as a fresh Connect device id, must
    /// not replace the user's own.
    @Test func `the container's settings win over what this domain already holds`() throws {
        defer { cleanUp() }
        try writeSettings(["playbackVolume": 0.3, "SpotifyDeviceId": "spotifly_42"])
        defaults.set("spotifly_7", forKey: "SpotifyDeviceId")
        defaults.set("dark", forKey: "appearanceMode")

        migrate()

        #expect(defaults.double(forKey: "playbackVolume") == 0.3)
        #expect(defaults.string(forKey: "SpotifyDeviceId") == "spotifly_42")
        #expect(defaults.string(forKey: "appearanceMode") == "dark")
        #expect(defaults.bool(forKey: ContainerMigration.doneKey))
    }

    @Test func `it runs once`() throws {
        defer { cleanUp() }
        try writeSettings(["playbackVolume": 0.3])
        migrate()

        try writeSettings(["playbackVolume": 0.3, "later": true])
        migrate()

        #expect(defaults.object(forKey: "later") == nil)
    }

    @Test func `the stored login moves into the keychain and the file goes`() throws {
        defer { cleanUp() }
        let login = StoredLogin(username: "someone", authData: Data([1, 2, 3]), authType: 1)
        try writeCredentials(JSONEncoder().encode(login))
        var saved: StoredLogin?

        migrate { saved = $0 }

        #expect(saved?.username == "someone")
        #expect(saved?.authData == Data([1, 2, 3]))
        #expect(saved?.authType == 1)
        #expect(!FileManager.default.fileExists(atPath: credentialsFile.path))
    }

    @Test func `an unreadable container is skipped, and not retried`() throws {
        defer { cleanUp() }
        let plist = container.appending(path: "Library/Preferences/\(domain).plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: plist)
        try writeCredentials(Data("not json".utf8))
        var saveCalled = false

        migrate { _ in saveCalled = true }

        #expect(!saveCalled)
        #expect(defaults.bool(forKey: ContainerMigration.doneKey))
        #expect(defaults.persistentDomain(forName: domain)?.keys.sorted() == [ContainerMigration.doneKey])
    }

    @Test func `a Mac that never ran the sandboxed app is only marked done`() {
        defer { cleanUp() }
        var saveCalled = false

        migrate { _ in saveCalled = true }

        #expect(!saveCalled)
        #expect(defaults.bool(forKey: ContainerMigration.doneKey))
    }
}
