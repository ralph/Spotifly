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

    /// Refresh once the access token has this many seconds or less of validity left.
    ///
    /// One grant now, so one policy: the launch path, the API clients and the accesspoint
    /// session all refresh on this. It used to live on the Web API's `SpotifyAuthResult` and be
    /// borrowed from here, which was the shared constant keeping two halves from drifting
    /// apart; there is only one half left.
    static let refreshBuffer: TimeInterval = 300

    /// Whether the token needs refreshing before use.
    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= Self.refreshBuffer
    }
}

nonisolated enum KeymasterAuthError: Error, LocalizedError, Equatable {
    case authorizationURLFailed
    case browserOpenFailed
    case stateMismatch
    case authorizationDenied(String)
    case noAuthorizationCode
    case tokenExchangeFailed(String)
    case malformedTokenResponse
    /// The refresh token is permanently dead — revoked, or expired under Spotify's six-month
    /// policy. Distinct from `tokenExchangeFailed` because it is the one token failure that
    /// must not be retried: the grant has to be discarded and the user sent through sign-in.
    case grantRevoked

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
        case .grantRevoked:
            "Session expired, please sign in again"
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

        let body = formURLEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI(port: port),
            "client_id": clientId,
            "code_verifier": verifier,
        ])

        return try await postToken(body: body, fallbackRefreshToken: nil)
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

    /// What a non-200 from the token endpoint means.
    ///
    /// **Only `invalid_grant` is fatal, and it is read from the body rather than inferred from
    /// the status.** Spotify answers 400 for several distinct things — a malformed request, a
    /// client id it does not know, a dead refresh token — and only the last of them says the
    /// grant is gone. Keying on the status would discard a perfectly good grant because a
    /// request was built wrong, and the user would be signed out by a bug in this app rather
    /// than by anything Spotify did. Everything else, 500s and unreadable bodies included, is
    /// transient by assumption: retrying a live grant costs a request, while discarding one
    /// costs a sign-in.
    ///
    /// The `{error, error_description}` shape is RFC 6749 §5.2 and was read off this same
    /// endpoint by the Web API half that used to live in `SpotifyAuth`. The *keymaster* client
    /// id's revocation response has not been observed directly — nothing here can revoke a
    /// grant on demand to look at it — so this trusts the endpoint rather than a measurement.
    static func tokenFailure(status: Int, body: Data) -> KeymasterAuthError {
        struct TokenErrorResponse: Decodable {
            let error: String
        }

        if let decoded = try? JSONDecoder().decode(TokenErrorResponse.self, from: body),
           decoded.error == "invalid_grant"
        {
            return .grantRevoked
        }

        let message = String(data: body, encoding: .utf8) ?? "unreadable response"
        return .tokenExchangeFailed("HTTP \(status): \(message)")
    }

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

    private static func postToken(body: Data, fallbackRefreshToken: String?) async throws -> KeymasterTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        debugLog("KeymasterAuth", "[POST] \(tokenEndpoint.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw tokenFailure(status: status, body: data)
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

/// PKCE bits. They were deliberately not shared with the dashboard OAuth's own copy, which was
/// on its way out; it has since gone, and this is the only copy left.
nonisolated enum PKCE {
    static func codeVerifier() -> String {
        randomBase64URL(byteCount: 64)
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String {
        randomBase64URL(byteCount: 16)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
