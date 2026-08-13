//
//  KeymasterAuth.swift
//  Spotifly
//
//  OAuth against Spotify's own desktop client id, over a loopback redirect.
//

import CryptoKit
import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// The result of a keymaster grant.
///
/// Unlike the Web API half, `refreshToken` is not optional: Spotify always issues one here,
/// and — measured, not assumed — **rotates it on every refresh**. Storing the replacement is
/// mandatory. Keeping the original makes the *second* refresh fail, roughly an hour in, which
/// presents as a spontaneous logout rather than as an auth bug.
nonisolated struct KeymasterTokens: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// The account the browser authorized as, which need not be the one signed in elsewhere.
    var username: String

    /// Whether the token needs refreshing before use, on the same buffer the Web API half uses.
    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= SpotifyAuthResult.refreshBufferSeconds
    }
}

nonisolated enum KeymasterAuthError: Error, LocalizedError {
    case authorizationURLFailed
    case browserOpenFailed
    case stateMismatch
    case authorizationDenied(String)
    case noAuthorizationCode
    case tokenExchangeFailed(String)
    case malformedTokenResponse

    var errorDescription: String? {
        switch self {
        case .authorizationURLFailed:
            "Could not build the Spotify authorization URL"
        case .browserOpenFailed:
            "Could not open the browser for Spotify authorization"
        case .stateMismatch:
            "The Spotify redirect did not match this request"
        case let .authorizationDenied(reason):
            "Spotify declined the authorization: \(reason)"
        case .noAuthorizationCode:
            "The Spotify redirect carried no authorization code"
        case let .tokenExchangeFailed(message):
            "Token exchange failed: \(message)"
        case .malformedTokenResponse:
            "The token response could not be read"
        }
    }
}

/// The grant that authorizes everything: the accesspoint session, pathfinder GraphQL and
/// spclient REST all run on the token this mints.
///
/// It is a plain PKCE flow — no DPoP proof, no client token on the exchange. Both were tested
/// against the live service and neither is required; see
/// `plans/single-grant-partner-api.md` for the probe this rests on.
nonisolated enum KeymasterAuth {
    /// Spotify's desktop client id, the same one librespot defaults to
    /// (`SessionConfig::default().client_id`). It is the only id that can obtain the client
    /// token the partner APIs require — a dashboard id gets 400 from `clienttoken.spotify.com`
    /// — and conversely it gets 429 from every `api.spotify.com` endpoint.
    static let clientId = "65b708073fc0480ea92a077233ca87bd"

    /// Matches the scope list the Rust grant requested, which is what the desktop client asks
    /// for. Narrowing it is a separate change with its own testing.
    static let scopes: [String] = [
        "app-remote-control",
        "playlist-modify",
        "playlist-modify-private",
        "playlist-modify-public",
        "playlist-read",
        "playlist-read-collaborative",
        "playlist-read-private",
        "streaming",
        "ugc-image-upload",
        "user-follow-modify",
        "user-follow-read",
        "user-library-modify",
        "user-library-read",
        "user-modify",
        "user-modify-playback-state",
        "user-modify-private",
        "user-personalized",
        "user-read-birthdate",
        "user-read-currently-playing",
        "user-read-email",
        "user-read-play-history",
        "user-read-playback-position",
        "user-read-playback-state",
        "user-read-private",
        "user-read-recently-played",
        "user-top-read",
    ]

    private static let authorizeEndpoint = "https://accounts.spotify.com/authorize"
    private static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!

    // MARK: - The flow

    /// Runs the grant: opens the browser, waits for the loopback redirect, exchanges the code.
    ///
    /// Blocks on a human, so callers should not run it at a user-initiated QoS.
    static func authorize() async throws -> KeymasterTokens {
        let server = LoopbackCallbackServer()
        let port = try await server.start()

        let verifier = PKCE.codeVerifier()
        let state = PKCE.randomState()

        guard let url = authorizationURL(
            port: port,
            challenge: PKCE.codeChallenge(for: verifier),
            state: state,
        ) else {
            await server.stop()
            throw KeymasterAuthError.authorizationURLFailed
        }

        guard openInBrowser(url) else {
            await server.stop()
            throw KeymasterAuthError.browserOpenFailed
        }

        let callback = try await server.waitForCallback()
        let code = try authorizationCode(from: callback, expectedState: state)

        return try await exchange(code: code, verifier: verifier, port: port)
    }

    /// Exchanges a refreshed token, returning the *new* refresh token with it.
    static func refresh(refreshToken: String) async throws -> KeymasterTokens {
        let body = formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ])

        // Spotify may return the same refresh token or a new one; either way what comes back
        // is what must be stored. Falling back to the token we sent keeps that invariant when
        // the response omits it.
        return try await postToken(body: body, fallbackRefreshToken: refreshToken)
    }

    // MARK: - Pieces, kept testable

    /// Builds the authorization URL. The redirect must match the port actually listening.
    static func authorizationURL(port: UInt16, challenge: String, state: String) -> URL? {
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI(port: port)),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        return components?.url
    }

    /// The path is `/login` because that is what the client id is registered with.
    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/login"
    }

    /// Reads the code out of the redirect, rejecting anything that is not the request we made.
    static func authorizationCode(from callback: URLComponents, expectedState: String) throws -> String {
        let items = callback.queryItems ?? []

        // Checked first, before the code *and* before any error: Spotify's own denial redirect
        // carries the state, so anything without it is not from this request. Trusting an
        // unauthenticated `error=` would let any local process that can reach the loopback
        // port abort a grant the user is in the middle of completing.
        guard let state = items.first(where: { $0.name == "state" })?.value, state == expectedState else {
            throw KeymasterAuthError.stateMismatch
        }

        if let error = items.first(where: { $0.name == "error" })?.value {
            throw KeymasterAuthError.authorizationDenied(error)
        }

        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw KeymasterAuthError.noAuthorizationCode
        }

        return code
    }

    /// Parses a token response into tokens, resolving expiry against a caller-supplied `now`
    /// so tests do not depend on the clock.
    static func parseTokenResponse(
        _ data: Data,
        fallbackRefreshToken: String?,
        now: Date = Date(),
    ) throws -> KeymasterTokens {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw KeymasterAuthError.malformedTokenResponse
        }

        guard let refreshToken = json["refresh_token"] as? String ?? fallbackRefreshToken else {
            throw KeymasterAuthError.malformedTokenResponse
        }

        let expiresIn = json["expires_in"] as? Double ?? 3600

        // The accesspoint needs the username and only this response carries it, so a refresh
        // that omits it must not blank the stored one.
        let username = json["username"] as? String ?? ""

        return KeymasterTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            username: username,
        )
    }

    static func formURLEncoded(_ parameters: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        let encoded = parameters
            .map { key, value in
                let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(escaped)"
            }
            .joined(separator: "&")

        return Data(encoded.utf8)
    }

    // MARK: - Private

    private static func exchange(code: String, verifier: String, port: UInt16) async throws -> KeymasterTokens {
        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI(port: port),
            "client_id": clientId,
            "code_verifier": verifier,
        ])

        return try await postToken(body: body, fallbackRefreshToken: nil)
    }

    private static func postToken(body: Data, fallbackRefreshToken: String?) async throws -> KeymasterTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let urlString = tokenEndpoint.absoluteString
        debugLog("KeymasterAuth", "[POST] \(urlString)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "unreadable response"
            throw KeymasterAuthError.tokenExchangeFailed(message)
        }

        return try parseTokenResponse(data, fallbackRefreshToken: fallbackRefreshToken)
    }

    private static func openInBrowser(_ url: URL) -> Bool {
        #if canImport(AppKit)
            return NSWorkspace.shared.open(url)
        #else
            return false
        #endif
    }
}

/// PKCE bits, kept here rather than shared with `SpotifyAuth`: that file is scheduled for
/// deletion once the dashboard half goes, and reaching into it would tie the new flow to code
/// on its way out.
nonisolated enum PKCE {
    static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
