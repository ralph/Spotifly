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

/// Reads and writes the stored login. One file, app-container protected —
/// the same trust model librespot's own credential cache uses.
///
/// Not thread-safe by itself; all callers reach it through the client actor.
public nonisolated struct StoredCredentialsStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spotifly", isDirectory: true)
        fileURL = base.appendingPathComponent("credentials.json")
    }

    public func load() -> StoredLogin? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredLogin.self, from: data)
    }

    public func save(_ login: StoredLogin) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(login).write(to: fileURL, options: .atomic)
        } catch {
            debugLog("StoredCredentials", "Could not persist login: \(error)")
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
