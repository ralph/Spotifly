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

    /// Loads the OAuth result from the keychain and attempts to refresh if expired
    /// - Returns: A valid auth result, or nil if unable to load/refresh
    static func loadAuthResultWithRefresh() async -> SpotifyAuthResult? {
        guard let result = loadAuthResult() else {
            return nil
        }

        // Check if token is expired or expiring soon (within 5 minutes)
        let isExpired = result.expiresIn < 300 // 5 minutes

        if isExpired, let refreshToken = result.refreshToken {
            // Attempt to refresh the token
            do {
                let newResult = try await SpotifyAuth.refreshAccessToken(refreshToken: refreshToken)

                // Save the new result to keychain
                try saveAuthResult(newResult)

                return newResult
            } catch {
                #if DEBUG
                    print("Failed to refresh token: \(error)")
                #endif
                // If refresh fails, clear the stored credentials
                clearAuthResult()
                return nil
            }
        }

        // Token is still valid
        return result
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
