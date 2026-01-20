//
//  Credentials.swift
//  SwiftLibrespot
//
//  Token and credential management
//

import Foundation

/// Credentials for authenticating with Spotify
public struct SpotifyCredentials: Sendable {
    /// OAuth access token
    public let accessToken: String

    /// Token expiration timestamp (Unix milliseconds)
    public let expiresAt: UInt64?

    /// Token type (usually "Bearer")
    public let tokenType: String

    /// Scopes granted by this token
    public let scopes: [String]

    /// Username (required for access token auth per go-librespot)
    public let username: String?

    public nonisolated init(
        accessToken: String,
        expiresAt: UInt64? = nil,
        tokenType: String = "Bearer",
        scopes: [String] = [],
        username: String? = nil,
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scopes = scopes
        self.username = username
    }

    /// Returns true if the token has expired
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return now >= expiresAt
    }

    /// Returns true if the token will expire within the given seconds
    public func willExpireSoon(withinSeconds: Int = 300) -> Bool {
        guard let expiresAt else { return false }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let buffer = UInt64(withinSeconds * 1000)
        return now + buffer >= expiresAt
    }
}

/// Stored authentication data from a previous session
public struct StoredCredentials: Codable, Sendable {
    /// Username (email or Spotify username)
    public let username: String

    /// Reusable authentication blob (encrypted)
    public let authData: Data

    /// Authentication type
    public let authType: Int

    public init(username: String, authData: Data, authType: Int) {
        self.username = username
        self.authData = authData
        self.authType = authType
    }
}
