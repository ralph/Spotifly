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
    /// Shared keychain access group - allows both dev and release builds to access the same items
    /// Format: TeamID.groupName (must match keychain-access-groups in entitlements)
    private nonisolated static let accessGroup = "89S4HZY343.com.spotifly.keychain"

    // MARK: - The dashboard grant, which no longer exists

    /// Deletes what the dashboard app left behind: the Web API access and refresh tokens, and
    /// the client id the user typed in to obtain them.
    ///
    /// Housekeeping on someone else's machine, run once per launch because there is nowhere
    /// cheaper to run it. The refresh token is a live credential for an app Spotifly no longer
    /// speaks to, and leaving it in the user's keychain forever is not ours to do. Delete this
    /// once enough releases have passed that no installed copy still holds one.
    nonisolated static func purgeDashboardGrant() {
        for key in ["spotify_access_token", "spotify_refresh_token", "spotify_expires_at"] {
            delete(key: key, service: "com.spotifly.oauth")
        }
        delete(key: "spotify_custom_client_id", service: "com.spotifly.config")
    }

    // MARK: - Keymaster grant

    private nonisolated static let keymasterService = "com.spotifly.keymaster"
    private nonisolated static let keymasterTokensKey = "keymaster_tokens"

    /// Stored as one item rather than a key per field, which is how the Web API tokens were
    /// kept. The four values are only meaningful together — an access token paired with another
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
