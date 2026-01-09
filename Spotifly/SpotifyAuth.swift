//
//  SpotifyAuth.swift
//  Spotifly
//
//  Dual authentication implementation:
//  - Keymaster auth (default): Uses librespot-oauth with official Spotify desktop client ID
//  - Custom client ID auth: Uses ASWebAuthenticationSession with user's client ID
//

import AuthenticationServices
import CryptoKit
import Foundation
import SpotiflyRust

/// Actor that manages Spotify authentication and player operations
@globalActor
actor SpotifyAuthActor {
    static let shared = SpotifyAuthActor()
}

/// Result of a successful OAuth flow
struct SpotifyAuthResult: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: UInt64
}

/// Errors that can occur during Spotify authentication
enum SpotifyAuthError: Error, Sendable, LocalizedError {
    case authenticationFailed
    case noTokenAvailable
    case refreshFailed
    case invalidCallbackURL
    case noAuthorizationCode
    case tokenExchangeFailed(String)
    case pkceGenerationFailed
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "Authentication failed"
        case .noTokenAvailable:
            "No token available"
        case .refreshFailed:
            "Failed to refresh token"
        case .invalidCallbackURL:
            "Invalid callback URL"
        case .noAuthorizationCode:
            "No authorization code received"
        case let .tokenExchangeFailed(message):
            "Token exchange failed: \(message)"
        case .pkceGenerationFailed:
            "Failed to generate PKCE codes"
        case .userCancelled:
            "User cancelled authentication"
        }
    }
}

/// Helper class to manage the auth session and its delegate (for ASWebAuthenticationSession)
private final class AuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        await MainActor.run {
            precondition(Thread.isMainThread, "ASWebAuthenticationSession must start on main thread")
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Create completion handler in nonisolated context to avoid isolation checking
            let completionHandler: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                        continuation.resume(throwing: SpotifyAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.invalidCallbackURL)
                }
            }

            // Access MainActor-isolated self to configure session
            MainActor.assumeIsolated {
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackURLScheme,
                    completionHandler: completionHandler,
                )

                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        }
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// Token response from Spotify API
private struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

/// Swift implementation of dual Spotify OAuth authentication
enum SpotifyAuth {
    // MARK: - PKCE Helper Functions (for ASWebAuthenticationSession)

    /// Converts data to base64url encoding (RFC 4648)
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a random code verifier for PKCE
    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    /// Generates a code challenge from the code verifier using SHA256
    private static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    /// Generates a random state parameter for OAuth
    private static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    /// Encodes a dictionary as URL form data
    private static func formURLEncode(_ parameters: [String: String]) -> Data? {
        parameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    // MARK: - Public API

    /// Initiates the Spotify OAuth flow using the appropriate method based on auth mode.
    /// - Parameter useCustomClientId: Whether to use custom client ID (ASWebAuthenticationSession) or keymaster (librespot-oauth)
    /// - Returns: The authentication result containing tokens
    /// - Throws: SpotifyAuthError if authentication fails
    @MainActor
    static func authenticate(useCustomClientId: Bool) async throws -> SpotifyAuthResult {
        if useCustomClientId {
            try await authenticateWithASWebAuth()
        } else {
            try await authenticateWithLibrespot()
        }
    }

    // MARK: - ASWebAuthenticationSession (Custom Client ID)

    /// Authenticates using ASWebAuthenticationSession with custom client ID
    @MainActor
    private static func authenticateWithASWebAuth() async throws -> SpotifyAuthResult {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()

        let clientId = SpotifyConfig.getClientId(useCustomClientId: true)

        // Build the authorization URL
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.customRedirectUri),
            URLQueryItem(name: "scope", value: SpotifyConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]

        guard let authURL = components.url else {
            throw SpotifyAuthError.authenticationFailed
        }

        // Get the presentation anchor
        guard let anchor = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            throw SpotifyAuthError.authenticationFailed
        }

        // Create session manager and start auth
        let authSession = AuthenticationSession(anchor: anchor)
        let callbackURL = try await authSession.authenticate(
            url: authURL,
            callbackURLScheme: SpotifyConfig.customCallbackURLScheme,
        )

        // Parse the callback URL to extract the authorization code
        guard let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let queryItems = urlComponents.queryItems
        else {
            throw SpotifyAuthError.invalidCallbackURL
        }

        // Verify state matches
        guard let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
              returnedState == state
        else {
            throw SpotifyAuthError.authenticationFailed
        }

        // Check for errors
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            throw SpotifyAuthError.tokenExchangeFailed(error)
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.noAuthorizationCode
        }

        // Exchange authorization code for tokens
        return try await exchangeCodeForToken(code: code, codeVerifier: codeVerifier, clientId: clientId)
    }

    /// Exchanges an authorization code for access and refresh tokens (for ASWebAuthenticationSession)
    private static func exchangeCodeForToken(code: String, codeVerifier: String, clientId: String) async throws -> SpotifyAuthResult {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.customRedirectUri,
            "client_id": clientId,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SpotifyAuthError.tokenExchangeFailed(errorMessage)
        }

        return try parseTokenResponse(data: data)
    }

    // MARK: - Librespot OAuth (Keymaster)

    /// Authenticates using librespot-oauth with keymaster client ID
    @SpotifyAuthActor
    private static func authenticateWithLibrespot() async throws -> SpotifyAuthResult {
        let clientId = SpotifyConfig.keymasterClientId
        let redirectUri = SpotifyConfig.keymasterRedirectUri

        // Run the OAuth flow on a background thread since it blocks
        let result = await Task.detached {
            spotifly_start_oauth(clientId, redirectUri)
        }.value

        guard result == 0 else {
            throw SpotifyAuthError.authenticationFailed
        }

        guard spotifly_has_oauth_result() == 1 else {
            throw SpotifyAuthError.noTokenAvailable
        }

        // Get the access token
        guard let accessTokenPtr = spotifly_get_access_token() else {
            throw SpotifyAuthError.noTokenAvailable
        }
        let accessToken = String(cString: accessTokenPtr)
        spotifly_free_string(accessTokenPtr)

        // Get the refresh token (optional)
        var refreshToken: String?
        if let refreshTokenPtr = spotifly_get_refresh_token() {
            refreshToken = String(cString: refreshTokenPtr)
            spotifly_free_string(refreshTokenPtr)
        }

        // Get expiration time
        let expiresIn = spotifly_get_token_expires_in()

        return SpotifyAuthResult(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
        )
    }

    // MARK: - Token Refresh

    /// Refreshes the access token using a refresh token.
    /// - Parameters:
    ///   - refreshToken: The refresh token to use
    ///   - useCustomClientId: Whether to use custom client ID mode
    /// - Returns: The new authentication result containing fresh tokens
    /// - Throws: SpotifyAuthError if refresh fails
    static func refreshAccessToken(refreshToken: String, useCustomClientId: Bool) async throws -> SpotifyAuthResult {
        if useCustomClientId {
            try await refreshWithASWebAuth(refreshToken: refreshToken)
        } else {
            try await refreshWithLibrespot(refreshToken: refreshToken)
        }
    }

    /// Refreshes token using Spotify API (for ASWebAuthenticationSession/custom client ID)
    private static func refreshWithASWebAuth(refreshToken: String) async throws -> SpotifyAuthResult {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        let clientId = SpotifyConfig.getClientId(useCustomClientId: true)

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw SpotifyAuthError.refreshFailed
        }

        return try parseTokenResponse(data: data)
    }

    /// Refreshes token using librespot-oauth (for keymaster)
    @SpotifyAuthActor
    private static func refreshWithLibrespot(refreshToken: String) async throws -> SpotifyAuthResult {
        let clientId = SpotifyConfig.keymasterClientId
        let redirectUri = SpotifyConfig.keymasterRedirectUri

        // Run the token refresh on a background thread since it blocks
        let result = await Task.detached {
            spotifly_refresh_access_token(clientId, redirectUri, refreshToken)
        }.value

        guard result == 0 else {
            throw SpotifyAuthError.refreshFailed
        }

        guard spotifly_has_oauth_result() == 1 else {
            throw SpotifyAuthError.noTokenAvailable
        }

        // Get the new access token
        guard let accessTokenPtr = spotifly_get_access_token() else {
            throw SpotifyAuthError.noTokenAvailable
        }
        let accessToken = String(cString: accessTokenPtr)
        spotifly_free_string(accessTokenPtr)

        // Get the new refresh token (optional)
        var newRefreshToken: String?
        if let refreshTokenPtr = spotifly_get_refresh_token() {
            newRefreshToken = String(cString: refreshTokenPtr)
            spotifly_free_string(refreshTokenPtr)
        }

        // Get expiration time
        let expiresIn = spotifly_get_token_expires_in()

        return SpotifyAuthResult(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn,
        )
    }

    /// Parses the token response from Spotify
    private static func parseTokenResponse(data: Data) throws -> SpotifyAuthResult {
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        return SpotifyAuthResult(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresIn: UInt64(tokenResponse.expiresIn),
        )
    }

    /// Clears any stored OAuth result (no-op for ASWebAuth, clears Rust state for librespot)
    static func clearAuthResult() {
        spotifly_clear_oauth_result()
    }
}
