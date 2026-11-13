//
//  StoredCredentialsStore.swift
//  SwiftLibrespot
//
//  Persists the AP welcome's reusable credentials so later sessions can log
//  in without a fresh browser grant.
//

import Foundation

/// A reusable accesspoint login, captured from `APWelcome`.
public nonisolated struct StoredLogin: Codable, Sendable {
    public let username: String
    /// The reusable auth blob (`APWelcome.reusableAuthCredentials`), used with
    /// the `.storedSpotifyCredentials` auth type.
    public let authData: Data
    public let authType: UInt32

    public init(username: String, authData: Data, authType: UInt32) {
        self.username = username
        self.authData = authData
        self.authType = authType
    }
}

/// Reads and writes the stored login, which lives in the keychain beside the keymaster grant.
///
/// It was `credentials.json` in Application Support, which the App Sandbox container kept
/// from other apps. Without the sandbox any process of the user could read that file, so it
/// moved; `ContainerMigration` brings an existing one across once.
///
/// Not thread-safe by itself; all callers reach it through the client actor.
public nonisolated struct StoredCredentialsStore {
    public init() {}

    public func load() -> StoredLogin? {
        KeychainManager.loadStoredLogin()
    }

    public func save(_ login: StoredLogin) {
        do {
            try KeychainManager.saveStoredLogin(login)
        } catch {
            debugLog("StoredCredentials", "Could not persist login: \(error)")
        }
    }

    public func clear() {
        KeychainManager.clearStoredLogin()
    }
}
