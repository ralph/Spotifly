//
//  SpotifyAuth.swift
//  Spotifly
//
//  Swift implementation of Spotify OAuth using ASWebAuthenticationSession with PKCE
//

import AuthenticationServices
import CryptoKit
import Foundation

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

/// Helper class to manage the auth session and its delegate
private final class AuthenticationSession: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private let anchor: ASPresentationAnchor
    private nonisolated(unsafe) var session: ASWebAuthenticationSession?
    private nonisolated(unsafe) var continuation: CheckedContinuation<URL, Error>?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        // Must be called from main actor but method itself is nonisolated
        await MainActor.run {
            precondition(Thread.isMainThread, "ASWebAuthenticationSession must start on main thread")
        }

        // Sendable wrapper for the continuation box
        final class ContinuationBox: @unchecked Sendable {
            var continuation: CheckedContinuation<URL, Error>?
        }

        let box = ContinuationBox()

        return try await withCheckedThrowingContinuation { continuation in
            box.continuation = continuation

            // Create completion handler in nonisolated context to avoid isolation checking
            let completionHandler: @Sendable (URL?, Error?) -> Void = { callbackURL, error in
                // Access continuation safely
                guard let cont = box.continuation else { return }
                box.continuation = nil

                if let error {
                    if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                        cont.resume(throwing: SpotifyAuthError.userCancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                } else if let callbackURL {
                    cont.resume(returning: callbackURL)
                } else {
                    cont.resume(throwing: SpotifyAuthError.invalidCallbackURL)
                }
            }

            // We know we're on main thread, use assumeIsolated to access MainActor state
            MainActor.assumeIsolated {
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackURLScheme,
                    completionHandler: completionHandler,
                )

                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                session.start()
            }
        }
    }

    nonisolated func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// Swift implementation of Spotify OAuth using ASWebAuthenticationSession with PKCE
enum SpotifyAuth {
    // MARK: - PKCE Helper Functions

    /// Generates a random code verifier for PKCE
    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a code challenge from the code verifier using SHA256
    private static func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates a random state parameter for OAuth
    private static func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Public API

    /// Initiates the Spotify OAuth flow using ASWebAuthenticationSession.
    /// - Returns: The authentication result containing tokens
    /// - Throws: SpotifyAuthError if authentication fails
    @MainActor
    static func authenticate() async throws -> SpotifyAuthResult {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()

        // Build the authorization URL
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfig.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfig.redirectUri),
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
            callbackURLScheme: SpotifyConfig.callbackURLScheme,
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
        return try await exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
    }

    /// Exchanges an authorization code for access and refresh tokens
    private static func exchangeCodeForToken(code: String, codeVerifier: String) async throws -> SpotifyAuthResult {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectUri,
            "client_id": SpotifyConfig.clientId,
            "code_verifier": codeVerifier,
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SpotifyAuthError.tokenExchangeFailed(errorMessage)
        }

        return try parseTokenResponse(data: data)
    }

    /// Refreshes the access token using a refresh token.
    /// - Parameter refreshToken: The refresh token to use
    /// - Returns: The new authentication result containing fresh tokens
    /// - Throws: SpotifyAuthError if refresh fails
    @MainActor
    static func refreshAccessToken(refreshToken: String) async throws -> SpotifyAuthResult {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": SpotifyConfig.clientId,
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw SpotifyAuthError.refreshFailed
        }

        return try parseTokenResponse(data: data)
    }

    /// Parses the token response from Spotify
    private static func parseTokenResponse(data: Data) throws -> SpotifyAuthResult {
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let token_type: String
            let scope: String?
        }

        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)

        return SpotifyAuthResult(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresIn: UInt64(tokenResponse.expires_in),
        )
    }

    /// Clears any stored OAuth result (no-op for this implementation, keychain handles storage)
    static func clearAuthResult() {
        // No-op - keychain manager handles clearing
    }
}
