//
//  AuthViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class AuthViewModel {
    var isAuthenticating = false
    var authResult: SpotifyAuthResult?
    var errorMessage: String?
    var isLoading = true

    init() {
        // Try to load existing auth from keychain on init
        loadFromKeychain()
    }

    func loadFromKeychain() {
        isLoading = true
        Task {
            // Attempt to load and refresh if needed
            if let savedResult = await KeychainManager.loadAuthResultWithRefresh() {
                await MainActor.run {
                    self.authResult = savedResult
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    func startOAuth(useCustomClientId: Bool) {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                let result = try await SpotifyAuth.authenticate(useCustomClientId: useCustomClientId)
                self.authResult = result
                self.isAuthenticating = false

                // Save to keychain
                do {
                    try KeychainManager.saveAuthResult(result)
                } catch {
                    print("Failed to save to keychain: \(error)")
                }
            } catch {
                self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                self.isAuthenticating = false
            }
        }
    }

    func logout() {
        SpotifyAuth.clearAuthResult()
        KeychainManager.clearAuthResult()
        authResult = nil
    }
}
