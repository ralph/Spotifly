//
//  Credentials.swift
//  SwiftLibrespot
//
//  Credential types for authenticating with Spotify
//

import Foundation

/// What an accesspoint login authenticates with.
///
/// Exactly one of the two fields is set, mirroring the two auth types the
/// protocol supports: a fresh OAuth token (the first login on a machine) or
/// the reusable blob captured from an earlier `APWelcome`.
public nonisolated struct APCredentials: Sendable {
    /// Account name sent alongside the credentials.
    public let username: String

    /// OAuth access token, for `.spotifyToken` logins.
    public let accessToken: String?

    /// Reusable credential blob, for `.storedAPCredentials` logins.
    public let storedAuthData: Data?

    public static func accessToken(_ token: String, username: String) -> APCredentials {
        APCredentials(username: username, accessToken: token, storedAuthData: nil)
    }

    public static func stored(username: String, authData: Data) -> APCredentials {
        APCredentials(username: username, accessToken: nil, storedAuthData: authData)
    }

    private init(username: String, accessToken: String?, storedAuthData: Data?) {
        self.username = username
        self.accessToken = accessToken
        self.storedAuthData = storedAuthData
    }
}
