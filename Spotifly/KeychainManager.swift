//
//  KeychainManager.swift
//  Spotifly
//
//  Manages secure storage of Spotify OAuth tokens in the macOS/iOS Keychain
//

import Foundation
import Security

/// Manages secure storage of authentication tokens in the Keychain
enum KeychainManager {
    private nonisolated static let service = "com.spotifly.oauth"
    private static let accessTokenKey = "spotify_access_token"
    private static let refreshTokenKey = "spotify_refresh_token"
    private static let expiresAtKey = "spotify_expires_at"

    /// Shared keychain access group - allows both dev and release builds to access the same items
    /// Format: TeamID.groupName (must match keychain-access-groups in entitlements)
    private nonisolated static let accessGroup = "89S4HZY343.com.spotifly.keychain"

    // MARK: - Public API

    /// Saves the OAuth result to the keychain
    static func saveAuthResult(_ result: SpotifyAuthResult) throws {
        // Calculate absolute expiration time
        let expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn))

        try save(key: accessTokenKey, data: result.accessToken.data(using: .utf8)!)

        if let refreshToken = result.refreshToken {
            try save(key: refreshTokenKey, data: refreshToken.data(using: .utf8)!)
        }

        // Store expiration as an ISO8601 string
        let expiresAtString = expiresAt.ISO8601Format()
        try save(key: expiresAtKey, data: expiresAtString.data(using: .utf8)!)
    }

    /// Loads the OAuth result from the keychain, returns nil if not found or expired
    /// Note: This method does NOT attempt to refresh expired tokens. Use loadAuthResultWithRefresh() for that.
    static func loadAuthResult() -> SpotifyAuthResult? {
        guard let accessTokenData = load(key: accessTokenKey),
              let accessToken = String(data: accessTokenData, encoding: .utf8),
              let expiresAtData = load(key: expiresAtKey),
              let expiresAtString = String(data: expiresAtData, encoding: .utf8)
        else {
            return nil
        }

        guard let expiresAt = try? Date(expiresAtString, strategy: .iso8601) else {
            return nil
        }

        // Calculate remaining seconds
        let now = Date()
        let expiresIn = UInt64(max(0, expiresAt.timeIntervalSince(now)))

        // Load optional refresh token
        var refreshToken: String? = nil
        if let refreshTokenData = load(key: refreshTokenKey) {
            refreshToken = String(data: refreshTokenData, encoding: .utf8)
        }

        return SpotifyAuthResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
        )
    }

    /// Refreshes the access token and persists the outcome — the single source of
    /// truth for the refresh-and-store policy used by both the launch path and the
    /// runtime session.
    ///
    /// - On success: the new tokens are saved to the keychain and returned.
    /// - On `SpotifyAuthError.tokenRevoked` (`invalid_grant`): the stored
    ///   credentials are discarded — per Spotify's token-expiration policy the
    ///   token must not be reused — and the error is re-thrown so the caller can
    ///   send the user back through sign-in.
    /// - On a transient failure: the error is re-thrown *without* clearing, so the
    ///   caller can keep the existing token and retry later.
    static func refreshAndPersist(refreshToken: String) async throws -> SpotifyAuthResult {
        do {
            let newResult = try await SpotifyAuth.refreshAccessToken(refreshToken: refreshToken)
            try? saveAuthResult(newResult)
            return newResult
        } catch SpotifyAuthError.tokenRevoked {
            clearAuthResult()
            throw SpotifyAuthError.tokenRevoked
        }
    }

    /// Loads the OAuth result from the keychain and attempts to refresh if expired
    /// - Returns: A valid auth result, or nil if unable to load/refresh
    static func loadAuthResultWithRefresh() async -> SpotifyAuthResult? {
        guard let result = loadAuthResult() else {
            return nil
        }

        // Still valid, or nothing to refresh with — use as-is.
        guard result.expiresIn < UInt64(SpotifyAuthResult.refreshBufferSeconds),
              let refreshToken = result.refreshToken
        else {
            return result
        }

        // `refreshAndPersist` discards the token on a revoked grant; a transient
        // failure leaves it in place so a later relaunch can recover.
        return try? await refreshAndPersist(refreshToken: refreshToken)
    }

    /// Clears all stored OAuth data from the keychain
    static func clearAuthResult() {
        delete(key: accessTokenKey)
        delete(key: refreshTokenKey)
        delete(key: expiresAtKey)
    }

    /// Checks if a valid (non-expired) auth result exists
    static var hasValidAuthResult: Bool {
        loadAuthResult() != nil
    }

    // MARK: - Custom Client ID

    /// Saves a custom Spotify Client ID to the keychain
    nonisolated static func saveCustomClientId(_ clientId: String) throws {
        try save(
            key: "spotify_custom_client_id",
            data: clientId.data(using: .utf8)!,
            service: "com.spotifly.config",
        )
    }

    /// Loads the custom Spotify Client ID from the keychain, returns nil if not found
    nonisolated static func loadCustomClientId() -> String? {
        guard let data = load(
            key: "spotify_custom_client_id",
            service: "com.spotifly.config",
        ),
            let clientId = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return clientId
    }

    /// Clears the custom Client ID from the keychain
    nonisolated static func clearCustomClientId() {
        delete(key: "spotify_custom_client_id", service: "com.spotifly.config")
    }

    // MARK: - Keymaster grant

    private nonisolated static let keymasterService = "com.spotifly.keymaster"
    private nonisolated static let keymasterTokensKey = "keymaster_tokens"

    /// Stored as one item rather than a key per field, unlike the Web API tokens above.
    /// The four values are only meaningful together — an access token paired with another
    /// grant's expiry, or with a refresh token that has since rotated, is worse than nothing —
    /// and a single write cannot leave them half-updated.
    nonisolated static func saveKeymasterTokens(_ tokens: KeymasterTokens) throws {
        try save(
            key: keymasterTokensKey,
            data: JSONEncoder().encode(tokens),
            service: keymasterService,
        )
    }

    nonisolated static func loadKeymasterTokens() -> KeymasterTokens? {
        guard let data = load(key: keymasterTokensKey, service: keymasterService) else {
            return nil
        }
        return try? JSONDecoder().decode(KeymasterTokens.self, from: data)
    }

    nonisolated static func clearKeymasterTokens() {
        delete(key: keymasterTokensKey, service: keymasterService)
    }

    // MARK: - Private Keychain Operations

    private nonisolated static func save(key: String, data: Data) throws {
        try save(key: key, data: data, service: service)
    }

    private nonisolated static func load(key: String) -> Data? {
        load(key: key, service: service)
    }

    private nonisolated static func delete(key: String) {
        delete(key: key, service: service)
    }

    private nonisolated static func save(key: String, data: Data, service: String) throws {
        var addQuery = makeQuery(key: key, service: service)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateQuery = makeQuery(key: key, service: service)
            // Update in place so Keychain keeps existing trusted app ACL entries.
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]

            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                updateAttributes as CFDictionary,
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
            return
        }

        throw KeychainError.saveFailed(addStatus)
    }

    private nonisolated static func load(key: String, service: String) -> Data? {
        var query = makeQuery(key: key, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private nonisolated static func delete(key: String, service: String) {
        let query = makeQuery(key: key, service: service)
        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static func makeQuery(key: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}

/// Errors that can occur during keychain operations
enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .saveFailed(status):
            "Failed to save to keychain: \(status)"
        }
    }
}
