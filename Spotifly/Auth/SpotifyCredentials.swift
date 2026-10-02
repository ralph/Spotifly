//
//  SpotifyCredentials.swift
//  Spotifly
//
//  What every request to Spotify's own APIs carries, and the retries they share.
//

import Foundation

/// The credentials every request to Spotify's own APIs carries, and the retry that keeps them
/// fresh.
///
/// `api-partner` and `spclient` are separate hosts with separate request shapes, but they are
/// authorized identically — a keymaster bearer identifying the user and a client token
/// identifying the application, both from the single grant this app now performs (see
/// `plans/done/single-grant-partner-api.md`) — and they refuse identically. Held in one place so the
/// refusal rule below is written once rather than three times.
nonisolated struct SpotifyCredentials: Sendable {
    /// Injected so request construction and decoding can be tested without a network.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias Pause = @Sendable (Duration) async throws -> Void

    /// One attempt's outcome, naming the client token it carried so a refusal can name it too,
    /// and what Spotify said was wrong with that token, if it said anything.
    typealias Attempt = (body: Data, status: Int, clientToken: String?, clientTokenError: String?)

    /// The headers the desktop client sends. `App-Platform` and the xpui origin are not
    /// cosmetic — neither host is a public API, and the requests that work are the ones shaped
    /// like the client's own.
    static let appPlatform = "OSX_ARM64"
    static let origin = "https://xpui.app.spotify.com"

    /// Hoisted out of the default-argument lists that name it, where a closure literal is not
    /// isolation-checked: written inline, the hop onto `ClientTokenProvider` goes unnoticed and
    /// the `await` that expresses it is reported as unnecessary. The emitted code hops either
    /// way — the checking is what differs, and here the call is checked like any other.
    static let invalidateShared: @Sendable (String) async -> Void = {
        await ClientTokenProvider.shared.invalidate(rejected: $0)
    }

    let accessToken: @Sendable () async throws -> String
    let clientToken: @Sendable () async throws -> String
    let invalidateClientToken: @Sendable (String) async -> Void
    let transport: Transport
    /// Waits before a read is asked for again; see `retryingPassingFailures(_:)`. Injected so
    /// tests do not wait.
    let pause: Pause
    /// The pauses before a read is asked for again, one per retry: a page's. Playback waits on
    /// its reads, and sets shorter ones; see `SPClient.retryPauses`.
    var retryPauses: [Duration] = [.seconds(1), .seconds(3)]

    /// Signs a request as the desktop client: both credentials, and the headers naming which
    /// client is asking. Both, always — the bearer identifies the user, the client token the
    /// application, and these hosts want to see both.
    private func sign(_ request: inout URLRequest) async throws {
        request.setValue(Self.appPlatform, forHTTPHeaderField: "App-Platform")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        try await request.setValue("Bearer \(accessToken())", forHTTPHeaderField: "Authorization")
        try await request.setValue(clientToken(), forHTTPHeaderField: "Client-Token")
    }

    /// The app's own: the signed-in account's bearer and the shared client token, over the
    /// network.
    static let live = SpotifyCredentials(
        accessToken: { try await KeymasterSession.shared.accessToken() },
        clientToken: { try await ClientTokenProvider.shared.token() },
        invalidateClientToken: invalidateShared,
        transport: { try await URLSession.shared.data(for: $0) },
        pause: { try await Task.sleep(for: $0) },
    )

    /// Signs a request and sends it, naming the client token it carried.
    func attempt(_ request: URLRequest) async throws -> Attempt {
        var signed = request
        try await sign(&signed)
        let (data, response) = try await transport(signed)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (
            data,
            http.statusCode,
            signed.value(forHTTPHeaderField: "Client-Token"),
            http.value(forHTTPHeaderField: "client-token-error"),
        )
    }

    /// Sends a write, signed afresh for a second attempt if Spotify refuses its client token.
    func send(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        try await retryingRefusedToken { try await attempt(request) }
    }

    /// Sends a read, signed afresh for each attempt, and asks again after a refused client token
    /// or a failure that may pass.
    func read(_ request: URLRequest) async throws -> (body: Data, status: Int) {
        try await retryingPassingFailures {
            try await send(request)
        }
    }

    /// Runs the attempt, and runs it once more against a fresh client token when Spotify refuses
    /// the first: with a `client-token-error` header, or with a 401.
    ///
    /// The client token is the credential nothing else would notice: it is cached for the
    /// fortnight Spotify says it is good for, so a token refused before then would fail every
    /// request until the app is relaunched.
    ///
    /// - **A `client-token-error` header** on a failure is Spotify naming the client token as the
    ///   fault: a token it would not take was answered 400 with it
    ///   (`plans/done/refused-client-token-answers-400.md`). A 400 without it is a bad request,
    ///   which asking again would not mend.
    /// - **A 401** can be either credential. The bearer refreshes itself, so this costs one
    ///   wasted retry at worst.
    ///
    /// The token the request actually carried is named, not just "the current one" — concurrent
    /// requests share a token, so one dead token is refused several times over and the later
    /// refusals would otherwise discard the replacement the first one fetched.
    func retryingRefusedToken(
        _ attempt: () async throws -> Attempt,
    ) async throws -> (body: Data, status: Int) {
        let sent = try await attempt()
        let refused = sent.status == 401 || (sent.clientTokenError != nil && !(200 ..< 300).contains(sent.status))
        guard refused else { return (sent.body, sent.status) }
        debugLog("SpotifyCredentials", "HTTP \(sent.status)\(sent.clientTokenError.map { " (\($0))" } ?? ""); asking again with a new client token")

        if let rejected = sent.clientToken {
            await invalidateClientToken(rejected)
        }

        let retried = try await attempt()
        if let error = retried.clientTokenError, !(200 ..< 300).contains(retried.status) {
            debugLog("SpotifyCredentials", "HTTP \(retried.status) (\(error)) for the new client token too")
        }
        return (retried.body, retried.status)
    }

    /// Runs a read, and runs it again after a pause when it failed in a way that may pass on its
    /// own, soon, after each of `retryPauses`: the server's 5xx, or a connection that dropped or
    /// could not be made. Those leave the network up, so `NetworkMonitor` never sees a return,
    /// and the page or list showed its error until Try again was pressed.
    ///
    /// Not asked again: a write, which may have happened (`PathfinderOperation`'s
    /// `retriesPassingFailures`, spclient's `send`); anything that answers the same each time,
    /// such as a 404; a request made with no network at all, which the network's return asks
    /// again; a timeout, which has already waited a minute; and a 429, since a rate limit is the
    /// whole client's, and asking again at once only adds to it.
    func retryingPassingFailures(
        _ read: () async throws -> (body: Data, status: Int),
    ) async throws -> (body: Data, status: Int) {
        for delay in retryPauses {
            do {
                let sent = try await read()
                guard Self.mayPass(status: sent.status) else { return sent }
                debugLog("SpotifyCredentials", "HTTP \(sent.status); asking again in \(delay)")
            } catch where Self.mayPass(error) {
                debugLog("SpotifyCredentials", "\(error.localizedDescription); asking again in \(delay)")
            }
            try await pause(delay)
        }
        return try await read()
    }

    private static func mayPass(status: Int) -> Bool {
        (500 ... 599).contains(status)
    }

    /// A connection that dropped or could not be made, or spclient's preflight refused with a
    /// status that may pass, which comes before the read it clears.
    private static func mayPass(_ error: Error) -> Bool {
        switch error {
        case let error as URLError:
            [.networkConnectionLost, .cannotConnectToHost].contains(error.code)
        case let SpclientError.preflightRejected(status):
            mayPass(status: status)
        default:
            false
        }
    }
}
