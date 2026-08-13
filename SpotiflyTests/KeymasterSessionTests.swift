//
//  KeymasterSessionTests.swift
//  SpotiflyTests
//
//  Keeping one keymaster token valid, across refreshes that rotate it.
//

import Combine
import Foundation
@testable import Spotifly
import Testing

/// An in-memory stand-in for the keychain, which also records what was written.
///
/// The rule under test is a property of the *sequence* of refreshes — each one must spend the
/// token the previous one returned — so a store that cannot be inspected cannot check it.
private final class RecordingStore: KeymasterTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: KeymasterTokens?
    private(set) var writes: [KeymasterTokens] = []

    init(initial: KeymasterTokens? = nil) {
        stored = initial
    }

    func load() -> KeymasterTokens? {
        lock.withLock { stored }
    }

    func save(_ tokens: KeymasterTokens) throws {
        lock.withLock {
            stored = tokens
            writes.append(tokens)
        }
    }

    func clear() {
        lock.withLock {
            stored = nil
        }
    }
}

/// Records every refresh token it is asked to spend, and hands back a rotated one.
private final class SpyRefresher: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spent: [String] = []
    private var round = 0

    /// Spotify rotates on every refresh, so the stub does too.
    func refresh(_ token: String) async throws -> KeymasterTokens {
        lock.withLock {
            spent.append(token)
            round += 1
            return KeymasterTokens(
                accessToken: "access-\(round)",
                refreshToken: "refresh-\(round)",
                expiresAt: Date(timeIntervalSince1970: 10_000_000),
                username: "",
            )
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// Lets a test hold a refresh open at a chosen point, so a logout can be landed *inside* it.
///
/// Without this the stub throws before the test's next line runs, and a supersession test
/// silently exercises the ordinary path instead.
private actor Gate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func entered() {
        hasEntered = true
        for arrival in arrivals {
            arrival.resume()
        }
        arrivals.removeAll()
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
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private func tokens(
    access: String = "access-0",
    refresh: String = "refresh-0",
    expiresAt: Date,
    username: String = "someuser",
) -> KeymasterTokens {
    KeymasterTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, username: username)
}

struct KeymasterSessionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var buffer: TimeInterval {
        KeymasterTokens.refreshBuffer
    }

    @Test func `a token with time left is handed back untouched`() async throws {
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer + 600)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })

        #expect(try await session.accessToken(now: now) == "access-0")
        #expect(spy.spent.isEmpty)
    }

    @Test func `a token inside the refresh buffer is renewed first`() async throws {
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })

        #expect(try await session.accessToken(now: now) == "access-1")
        #expect(spy.spent == ["refresh-0"])
    }

    @Test func `the second refresh spends the rotated token, not the original`() async throws {
        // The whole point. Spotify invalidates the old refresh token on every refresh, so a
        // session that keeps sending the first one works once and then fails about an hour in,
        // which presents as a spontaneous logout rather than as an auth bug.
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })

        _ = try await session.accessToken(now: now)
        // The renewed token expires far in the future, so ask again from a later "now".
        _ = try await session.accessToken(now: Date(timeIntervalSince1970: 10_000_000))

        #expect(spy.spent == ["refresh-0", "refresh-1"])
    }

    @Test func `every refresh is persisted, so a relaunch resumes from the current token`() async throws {
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })

        _ = try await session.accessToken(now: now)

        #expect(store.writes.count == 1)
        #expect(store.load()?.refreshToken == "refresh-1")
        #expect(store.load()?.accessToken == "access-1")
    }

    @Test func `a refresh keeps the username the accesspoint needs`() async throws {
        // Only the initial exchange carries it; a refresh that omits it must not blank it.
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })

        _ = try await session.accessToken(now: now)

        #expect(store.load()?.username == "someuser")
        #expect(await session.username == "someuser")
    }

    @Test func `concurrent callers share one refresh`() async throws {
        // Two refreshes would each spend the same rotating token, and the loser would persist
        // a replacement Spotify has already invalidated.
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let spy = SpyRefresher()
        let session = KeymasterSession(store: store, refresher: { try await spy.refresh($0) })
        let asOf = now

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await session.accessToken(now: asOf) }
            }
            var collected: [String] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        #expect(results.allSatisfy { $0 == "access-1" })
        #expect(spy.spent == ["refresh-0"])
    }

    @Test func `asking for a token before any grant is an error, not an empty string`() async throws {
        let session = KeymasterSession(store: RecordingStore(), refresher: { _ in
            Issue.record("a session with no grant must not try to refresh")
            throw KeymasterSessionError.noGrant
        })

        await #expect(throws: KeymasterSessionError.self) {
            _ = try await session.accessToken(now: now)
        }
        #expect(await !session.hasGrant)
    }

    @Test func `adopting a grant persists it and makes it readable`() async throws {
        let store = RecordingStore()
        let session = KeymasterSession(store: store, refresher: { _ in
            Issue.record("a fresh grant needs no refresh")
            throw KeymasterSessionError.noGrant
        })

        let fresh = tokens(access: "brand-new", expiresAt: now.addingTimeInterval(3600))
        try await session.adopt(fresh)

        #expect(try await session.accessToken(now: now) == "brand-new")
        #expect(store.load() == fresh)
    }

    @Test func `a revoked grant is discarded rather than retried`() async throws {
        // Left in place, a dead refresh token is spent again by every later request and
        // survives relaunch in the keychain — the app fails forever and looks authorized.
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let session = KeymasterSession(store: store, refresher: { _ in
            throw KeymasterAuthError.grantRevoked
        })

        // Forgetting the tokens stops the retry loop; the announcement is what gets the user
        // to a screen they can sign in from, so it is half the fix and worth asserting.
        let announcements = Counter()
        let subscription = session.grantRevoked.sink { announcements.increment() }
        defer { subscription.cancel() }

        await #expect(throws: KeymasterSessionError.grantRevoked) {
            _ = try await session.accessToken(now: now)
        }

        #expect(store.load() == nil)
        #expect(await !session.hasGrant)
        #expect(announcements.value == 1)
    }

    @Test func `a transient failure keeps the grant`() async throws {
        // The other half of the rule, and the one that costs a sign-in to get wrong: a 500, a
        // dead network or a rate limit says nothing about whether the grant is still good.
        struct Transient: Error {}

        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let session = KeymasterSession(store: store, refresher: { _ in throw Transient() })

        await #expect(throws: Transient.self) {
            _ = try await session.accessToken(now: now)
        }

        #expect(store.load()?.refreshToken == "refresh-0")
        #expect(await session.hasGrant)
    }

    @Test func `a revocation that a logout outlived does not clear the grant behind it`() async throws {
        // The refresh spans a network call, so a logout and a fresh sign-in can both land
        // inside it. The revocation belongs to the token this run spent, not to the good grant
        // now holding the slot. The gate is what makes that orderable: without it the refusal
        // lands before the replacement and the test proves nothing.
        let gate = Gate()
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(buffer - 60)))
        let session = KeymasterSession(store: store, refresher: { _ in
            await gate.entered()
            await gate.wait()
            throw KeymasterAuthError.grantRevoked
        })

        let refreshing = Task { try await session.accessToken(now: now) }
        await gate.waitUntilEntered()

        await session.clear()
        let replacement = tokens(access: "brand-new", refresh: "fresh", expiresAt: now.addingTimeInterval(3600))
        try await session.adopt(replacement)

        await gate.open()
        _ = try? await refreshing.value

        #expect(store.load() == replacement)
        #expect(await session.hasGrant)
    }

    @Test func `clearing forgets the grant in memory and on disk`() async {
        let store = RecordingStore(initial: tokens(expiresAt: now.addingTimeInterval(3600)))
        let session = KeymasterSession(store: store, refresher: { _ in
            throw KeymasterSessionError.noGrant
        })

        await session.clear()

        #expect(store.load() == nil)
        #expect(await !session.hasGrant)
    }
}
