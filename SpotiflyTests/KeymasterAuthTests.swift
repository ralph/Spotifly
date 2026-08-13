//
//  KeymasterAuthTests.swift
//  SpotiflyTests
//
//  The grant that authorizes playback and the partner APIs from one token.
//

import Foundation
@testable import Spotifly
import Testing

/// What goes out in the authorization request.
///
/// The redirect is plain HTTP on loopback because that is what Spotify's desktop client id is
/// registered with — see `plans/single-grant-partner-api.md`.
struct KeymasterAuthorizationURLTests {
    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func `the request carries the desktop client id and a loopback redirect`() throws {
        let url = try #require(KeymasterAuth.authorizationURL(port: 51234, challenge: "chal", state: "st"))
        let items = try queryItems(url)

        #expect(url.host == "accounts.spotify.com")
        #expect(items["client_id"] == "65b708073fc0480ea92a077233ca87bd")
        #expect(items["redirect_uri"] == "http://127.0.0.1:51234/login")
        #expect(items["response_type"] == "code")
    }

    @Test func `the challenge is S256, never plain`() throws {
        let url = try #require(KeymasterAuth.authorizationURL(port: 1, challenge: "chal", state: "st"))
        let items = try queryItems(url)

        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == "chal")
    }

    @Test func `the redirect follows the port actually listening`() {
        // The port is assigned by the system, so a hardcoded redirect would point at whatever
        // else happened to be on it.
        #expect(KeymasterAuth.redirectURI(port: 9292) == "http://127.0.0.1:9292/login")
        #expect(KeymasterAuth.redirectURI(port: 65535) == "http://127.0.0.1:65535/login")
    }

    @Test func `a verifier produces the challenge Spotify will check`() {
        // RFC 7636's own example: verifier -> BASE64URL(SHA256(verifier)).
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func `base64url encoding leaves no characters a URL would escape`() {
        let encoded = PKCE.codeVerifier()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }
}

/// What comes back, and what must be rejected.
struct KeymasterCallbackTests {
    private func callback(_ query: String) throws -> URLComponents {
        try #require(URLComponents(string: "http://127.0.0.1:1/login?\(query)"))
    }

    @Test func `the code is read when the state matches`() throws {
        let code = try KeymasterAuth.authorizationCode(
            from: callback("code=abc123&state=expected"),
            expectedState: "expected",
        )
        #expect(code == "abc123")
    }

    @Test func `a redirect from another request is refused`() throws {
        // Anything can reach a loopback listener; only the state ties a redirect to this flow.
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.authorizationCode(
                from: callback("code=abc123&state=someone-else"),
                expectedState: "expected",
            )
        }
    }

    @Test func `a missing state is refused rather than trusted`() throws {
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.authorizationCode(from: callback("code=abc123"), expectedState: "expected")
        }
    }

    @Test func `an error without the state is treated as a stranger, not as a denial`() throws {
        // Spotify's own denial carries the state. Trusting an unauthenticated error would let
        // anything that can reach the loopback port abort a grant in progress.
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.authorizationCode(from: callback("error=access_denied"), expectedState: "expected")
        }
    }

    @Test func `a denial reports the reason instead of a missing code`() throws {
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.authorizationCode(
                from: callback("error=access_denied&state=expected"),
                expectedState: "expected",
            )
        }
    }

    @Test func `an empty code is not a code`() throws {
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.authorizationCode(from: callback("code=&state=expected"), expectedState: "expected")
        }
    }

    @Test func `the request line yields the query the browser sent`() throws {
        let request = "GET /login?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:51234\r\n\r\n"
        let components = try #require(LoopbackCallbackServer.parseRequestLine(request))
        let items = try #require(components.queryItems)

        #expect(items.first(where: { $0.name == "code" })?.value == "abc")
        #expect(items.first(where: { $0.name == "state" })?.value == "xyz")
    }

    @Test func `something that is not a GET request line is not parsed`() {
        #expect(LoopbackCallbackServer.parseRequestLine("POST /login HTTP/1.1\r\n\r\n") == nil)
        #expect(LoopbackCallbackServer.parseRequestLine("garbage") == nil)
    }
}

/// The token response, and the rotation that must survive it.
struct KeymasterTokenResponseTests {
    private func data(_ json: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: json)
    }

    @Test func `an exchange response is read whole`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try KeymasterAuth.parseTokenResponse(
            data([
                "access_token": "at",
                "refresh_token": "rt",
                "expires_in": 3600,
                "username": "someuser",
            ]),
            fallbackRefreshToken: nil,
            now: now,
        )

        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.username == "someuser")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func `a rotated refresh token replaces the one that was sent`() throws {
        // Spotify rotates on every refresh. Keeping the original makes the *second* refresh
        // fail, an hour later, looking like a spontaneous logout.
        let tokens = try KeymasterAuth.parseTokenResponse(
            data(["access_token": "at2", "refresh_token": "rt2", "expires_in": 3600]),
            fallbackRefreshToken: "rt1",
        )

        #expect(tokens.refreshToken == "rt2")
    }

    @Test func `a refresh that omits the token keeps the one that still works`() throws {
        let tokens = try KeymasterAuth.parseTokenResponse(
            data(["access_token": "at2", "expires_in": 3600]),
            fallbackRefreshToken: "rt1",
        )

        #expect(tokens.refreshToken == "rt1")
    }

    @Test func `an exchange with no refresh token at all is malformed`() throws {
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.parseTokenResponse(
                data(["access_token": "at", "expires_in": 3600]),
                fallbackRefreshToken: nil,
            )
        }
    }

    @Test func `a response without an access token is malformed`() throws {
        #expect(throws: KeymasterAuthError.self) {
            try KeymasterAuth.parseTokenResponse(data(["refresh_token": "rt"]), fallbackRefreshToken: nil)
        }
    }

    @Test func `expiry is judged on the same buffer the Web API half uses`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let buffer = SpotifyAuthResult.refreshBufferSeconds

        let fresh = KeymasterTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(buffer + 60), username: "u",
        )
        let stale = KeymasterTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(buffer - 60), username: "u",
        )

        #expect(!fresh.needsRefresh(now: now))
        #expect(stale.needsRefresh(now: now))
    }

    @Test func `form encoding escapes what a token body can contain`() throws {
        let body = KeymasterAuth.formURLEncoded(["code": "a+b/c=d", "client_id": "x"])
        let encoded = try #require(String(data: body, encoding: .utf8))

        #expect(encoded.contains("code=a%2Bb%2Fc%3Dd"))
        #expect(encoded.contains("client_id=x"))
    }
}
