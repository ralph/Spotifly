//
//  KeychainManager.swift
//  Spotifly
//
//  Manages secure storage of Spotify OAuth tokens in the macOS/iOS Keychain
//

import Foundation
import Security

/// Manages secure storage of authentication tokens in the Keychain
nonisolated enum KeychainManager {
    /// Shared keychain access group - allows both dev and release builds to access the same items
    /// Format: TeamID.groupName (must match keychain-access-groups in entitlements)
    private static let accessGroup = "89S4HZY343.com.spotifly.keychain"

    // MARK: - The dashboard grant, which no longer exists

    /// Deletes what the dashboard app left behind: the Web API access and refresh tokens, and
    /// the client id the user typed in to obtain them.
    ///
    /// Housekeeping on someone else's machine, run once per launch because there is nowhere
    /// cheaper to run it. The refresh token is a live credential for an app Spotifly no longer
    /// speaks to, and leaving it in the user's keychain forever is not ours to do. Delete this
    /// once enough releases have passed that no installed copy still holds one.
    static func purgeDashboardGrant() {
        for key in ["spotify_access_token", "spotify_refresh_token", "spotify_expires_at"] {
            delete(key: key, service: "com.spotifly.oauth")
        }
        delete(key: "spotify_custom_client_id", service: "com.spotifly.config")
    }

    // MARK: - Keymaster grant

    private static let keymasterService = "com.spotifly.keymaster"
    private static let keymasterTokensKey = "keymaster_tokens"

    /// Stored as one item rather than a key per field, which is how the Web API tokens were
    /// kept. The four values are only meaningful together — an access token paired with another
    /// grant's expiry, or with a refresh token that has since rotated, is worse than nothing —
    /// and a single write cannot leave them half-updated.
    static func saveKeymasterTokens(_ tokens: KeymasterTokens) throws {
        try save(
            key: keymasterTokensKey,
            data: JSONEncoder().encode(tokens),
            service: keymasterService,
        )
    }

    static func loadKeymasterTokens() -> KeymasterTokens? {
        guard let data = load(key: keymasterTokensKey, service: keymasterService) else {
            return nil
        }
        return try? JSONDecoder().decode(KeymasterTokens.self, from: data)
    }

    static func clearKeymasterTokens() {
        delete(key: keymasterTokensKey, service: keymasterService)
    }

    // MARK: - Stored accesspoint login, which no longer exists

    private static let storedLoginService = "com.spotifly.librespot"
    private static let storedLoginKey = "stored_login"

    /// Set once the stored login has been deleted, so the launch after does not ask again.
    static let storedLoginClearedKey = "clearedStoredLogin"

    /// Deletes the reusable accesspoint login the built-in player kept, which nothing reads
    /// since Soloist became the only player, and which is a live credential for the account.
    /// Once, at launch (`SpotiflyApp.init`), beside `ContainerMigration`, which deletes the file
    /// an older version kept it in: nothing writes it any more, so once is enough.
    static func clearStoredLoginOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: storedLoginClearedKey) else { return }
        delete(key: storedLoginKey, service: storedLoginService)
        defaults.set(true, forKey: storedLoginClearedKey)
    }

    // MARK: - Soloist key

    private static let soloistService = "com.spotifly.soloist"
    private static let soloistKey = "api_key"

    /// The key from Spotify's Soloist dashboard, which Soloist needs to start (`SoloistEngine`).
    static func saveSoloistKey(_ key: String) throws {
        try save(key: soloistKey, data: Data(key.utf8), service: soloistService)
    }

    static func loadSoloistKey() -> String? {
        load(key: soloistKey, service: soloistService).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Private Keychain Operations

    private static func save(key: String, data: Data, service: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        var addQuery = makeQuery(key: key, service: service)
        addQuery.merge(attributes) { _, new in new }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainError.saveFailed(addStatus)
        }

        // Update in place so Keychain keeps existing trusted app ACL entries.
        let updateStatus = SecItemUpdate(
            makeQuery(key: key, service: service) as CFDictionary,
            attributes as CFDictionary,
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    private static func load(key: String, service: String) -> Data? {
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

    private static func delete(key: String, service: String) {
        SecItemDelete(makeQuery(key: key, service: service) as CFDictionary)
    }

    private static func makeQuery(key: String, service: String) -> [String: Any] {
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
