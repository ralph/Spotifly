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
    private static let service = "com.spotifly.oauth"
    private static let accessTokenKey = "spotify_access_token"
    private static let refreshTokenKey = "spotify_refresh_token"
    private static let expiresAtKey = "spotify_expires_at"

    // MARK: - Public API

    /// Saves the OAuth result to the keychain
    static func saveAuthResult(_ result: SpotifyAuthResult) throws {
        // Calculate absolute expiration time
        let expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn))

        try save(key: accessTokenKey, data: result.accessToken.data(using: .utf8)!)

        if let refreshToken = result.refreshToken {
            try save(key: refreshTokenKey, data: refreshToken.data(using: .utf8)!)
        }

        // Store expiration as ISO8601 string
        let formatter = ISO8601DateFormatter()
        let expiresAtString = formatter.string(from: expiresAt)
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

        let formatter = ISO8601DateFormatter()
        guard let expiresAt = formatter.date(from: expiresAtString) else {
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
            // Attempt to refresh the token using the stored auth mode
            let useCustomClientId = loadUseCustomClientId()
            do {
                let newResult = try await SpotifyAuth.refreshAccessToken(
                    refreshToken: refreshToken,
                    useCustomClientId: useCustomClientId,
                )

                // Save the new result to keychain
                try saveAuthResult(newResult)

                return newResult
            } catch {
                print("Failed to refresh token: \(error)")
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
        // Delete any existing item first
        clearCustomClientId()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_custom_client_id",
            kSecValueData as String: clientId.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Loads the custom Spotify Client ID from the keychain, returns nil if not found
    nonisolated static func loadCustomClientId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_custom_client_id",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let clientId = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return clientId
    }

    /// Clears the custom Client ID from the keychain
    nonisolated static func clearCustomClientId() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_custom_client_id",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Auth Mode (Custom vs Keymaster)

    /// Saves whether user is using custom client ID mode
    nonisolated static func saveUseCustomClientId(_ useCustom: Bool) throws {
        // Delete any existing item first
        clearUseCustomClientId()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_use_custom_client_id",
            kSecValueData as String: (useCustom ? "true" : "false").data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Loads whether user is using custom client ID mode (default: false)
    nonisolated static func loadUseCustomClientId() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_use_custom_client_id",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return false // Default to keymaster auth
        }
        return value == "true"
    }

    /// Clears the auth mode setting from the keychain
    nonisolated static func clearUseCustomClientId() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.spotifly.config",
            kSecAttrAccount as String: "spotify_use_custom_client_id",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private Keychain Operations

    private static func save(key: String, data: Data) throws {
        // Delete any existing item first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
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
