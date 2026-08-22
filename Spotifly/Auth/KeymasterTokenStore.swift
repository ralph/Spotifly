//
//  KeymasterTokenStore.swift
//  Spotifly
//
//  Where the keymaster grant's tokens live between launches.
//

import Foundation

/// Storage for the keymaster tokens.
///
/// A protocol rather than a direct `KeychainManager` call so the rotation policy can be
/// tested without a keychain — the rule that matters (the response's refresh token replaces
/// the stored one) is a property of the *sequence* of refreshes, and a test that cannot
/// observe what was written cannot check it.
nonisolated protocol KeymasterTokenStoring: Sendable {
    func load() -> KeymasterTokens?
    func save(_ tokens: KeymasterTokens) throws
    func clear()
}

/// The real store, in the same keychain service the Web API half uses.
nonisolated struct KeymasterKeychainStore: KeymasterTokenStoring {
    func load() -> KeymasterTokens? {
        KeychainManager.loadKeymasterTokens()
    }

    func save(_ tokens: KeymasterTokens) throws {
        try KeychainManager.saveKeymasterTokens(tokens)
    }

    func clear() {
        KeychainManager.clearKeymasterTokens()
    }
}
