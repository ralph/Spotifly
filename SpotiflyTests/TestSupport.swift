//
//  TestSupport.swift
//  SpotiflyTests
//
//  What more than one suite needs: gates and counters for the concurrency tests, and the
//  stub-transport clients the network tests are written against.
//

import Foundation
@testable import Spotifly
import Testing

// MARK: - Gates

/// Holds a stubbed operation open until the test decides to let it finish.
///
/// Main-actor isolated, for the operation closures that run there: the services take
/// `@MainActor` operations, so a gate they await has to live on the same actor.
@MainActor
final class MainActorGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming {
            waiter.resume()
        }
    }
}

/// The same idea for the `Sendable` transports, which run wherever `URLSession` would.
///
/// `open()` sets the flag *and* drains the waiters, so a transport arriving either side of it
/// is released either way — the gate cannot strand one by losing a race with it.
///
/// `entered()` and `waitUntilEntered()` let a test land a second operation *inside* a held one.
/// Without them the stub returns before the test's next line runs, and a supersession test
/// silently exercises the ordinary path instead.
actor AsyncGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func entered() {
        hasEntered = true
        let resuming = arrivals
        arrivals.removeAll()
        for arrival in resuming {
            arrival.resume()
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming {
            waiter.resume()
        }
    }
}

// MARK: - Waiting

/// Yields until `condition` holds, so a test can wait for an unstructured task to reach a point
/// without sleeping for a fixed duration.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition never became true")
}

/// Yields enough times for pending main-actor work to reach its next suspension, so a following
/// assertion about what did *not* happen is meaningful.
@MainActor
func settle() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}

// MARK: - Counters and recorders

/// A counter the `@MainActor` operation closures can mutate directly.
@MainActor
final class MainActorCounter {
    var count = 0
}

/// A counter for the `@Sendable` stubs, which are called from wherever the client runs them.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var tally = 0

    var count: Int {
        lock.withLock { tally }
    }

    func increment() {
        lock.withLock { tally += 1 }
    }
}

/// Records what a `@Sendable` stub was asked for, in order.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    var values: [Value] {
        lock.withLock { recorded }
    }

    func record(_ value: Value) {
        lock.withLock { recorded.append(value) }
    }
}

// MARK: - Stubbed clients

func httpResponse(_ status: Int, url: URL = PartnerAPI.endpoint, headers: [String: String]? = nil) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

/// Credentials answered by `transport` rather than by the network. Its default fails every
/// request, for a test that sends none.
///
/// `invalidateClientToken` is left at the production default unless a test passes one, so a
/// test that is not about the client token behaves exactly as the app does.
///
/// A read retried after a failure that may pass does not wait, unless `pause` is given.
func spotifyCredentials(
    accessToken: String = "at",
    clientToken: String = "ct",
    invalidateClientToken: @escaping @Sendable (String) async -> Void = SpotifyCredentials.invalidateShared,
    pause: @escaping SpotifyCredentials.Pause = { _ in },
    transport: @escaping SpotifyCredentials.Transport = { _ in throw URLError(.notConnectedToInternet) },
) -> SpotifyCredentials {
    SpotifyCredentials(
        accessToken: { accessToken },
        clientToken: { clientToken },
        invalidateClientToken: invalidateClientToken,
        transport: transport,
        pause: pause,
    )
}

/// A `PartnerAPI` answered by `transport`; see `spotifyCredentials`.
func partnerAPI(
    accessToken: String = "at",
    clientToken: String = "ct",
    invalidateClientToken: @escaping @Sendable (String) async -> Void = SpotifyCredentials.invalidateShared,
    pause: @escaping SpotifyCredentials.Pause = { _ in },
    transport: @escaping PartnerAPI.Transport,
) -> PartnerAPI {
    PartnerAPI(credentials: spotifyCredentials(
        accessToken: accessToken,
        clientToken: clientToken,
        invalidateClientToken: invalidateClientToken,
        pause: pause,
        transport: transport,
    ))
}

/// The same for the REST half.
func spclientAPI(
    invalidateClientToken: @escaping @Sendable (String) async -> Void = SpotifyCredentials.invalidateShared,
    pause: @escaping SpotifyCredentials.Pause = { _ in },
    transport: @escaping SpclientAPI.Transport,
) -> SpclientAPI {
    SpclientAPI(credentials: spotifyCredentials(invalidateClientToken: invalidateClientToken, pause: pause, transport: transport))
}

// MARK: - Request bodies

/// That a JSON body says what a captured one says, key order aside.
func expectMatch(_ encoded: Data?, _ fixture: String) throws {
    let json = { (data: Data?) in data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? NSDictionary } }
    let ours = try #require(json(encoded))
    let theirs = try #require(json(Data(fixture.utf8)))
    #expect(ours == theirs)
}

// MARK: - Fixtures

/// Anchors `Bundle(for:)` to the test bundle, which carries `Fixtures/`.
private final class FixtureBundleToken {}

/// A captured payload from `SpotiflyTests/Fixtures`, by file name without its extension.
func fixtureData(_ name: String, withExtension fileExtension: String = "json") throws -> Data {
    let url = try #require(Bundle(for: FixtureBundleToken.self).url(forResource: name, withExtension: fileExtension))
    return try Data(contentsOf: url)
}

// MARK: - Measured values

extension Restrictions {
    /// A station's, as the context resolver named them for Song Radio on 2026-10-02: no shuffle
    /// and no repeat of the context, for "radio".
    static var radio: Restrictions {
        var restrictions = Restrictions()
        restrictions.togglingRepeatContext = ["radio"]
        restrictions.togglingShuffle = ["radio"]
        return restrictions
    }
}
