//
//  InFlightRequestsTests.swift
//  SpotiflyTests
//
//  Covers the two guarantees the services rely on: one run per key, and a run that
//  outlives the caller that started it.
//

@testable import Spotifly
import Testing

@MainActor
struct InFlightRequestsTests {
    @Test func `a second caller joins the running operation instead of starting another`() async throws {
        let requests = InFlightRequests<Int>()
        let gate = Gate()
        let runs = Counter()

        let first = Task { try await requests.run("k") { runs.count += 1; await gate.wait(); return runs.count } }
        try await waitUntil { requests.isRunning("k") }

        let second = Task { try await requests.run("k") { runs.count += 1; await gate.wait(); return runs.count } }
        await settle()

        #expect(runs.count == 1)

        gate.open()
        #expect(try await first.value == 1)
        #expect(try await second.value == 1)
    }

    @Test func `cancelling the caller does not cancel the run`() async throws {
        let requests = InFlightRequests<Int>()
        let gate = Gate()
        let didFinish = Counter()

        let caller = Task { try await requests.run("k") { await gate.wait(); didFinish.count += 1; return 7 } }
        try await waitUntil { requests.isRunning("k") }

        caller.cancel()
        gate.open()

        #expect(try await caller.value == 7)
        #expect(didFinish.count == 1)
    }

    @Test func `a failed run is not remembered, so the next caller retries`() async throws {
        let requests = InFlightRequests<Int>()
        let runs = Counter()

        await #expect(throws: TestFailure.self) {
            try await requests.run("k") { runs.count += 1; throw TestFailure() }
        }
        #expect(!requests.isRunning("k"))

        let value = try await requests.run("k") { runs.count += 1; return runs.count }
        #expect(value == 2)
    }

    @Test func `a cancelled run does not drop the run that replaced it`() async throws {
        let requests = InFlightRequests<Int>()
        let firstGate = Gate()
        let secondGate = Gate()

        let first = Task { try await requests.run("k") { await firstGate.wait(); return 1 } }
        try await waitUntil { requests.isRunning("k") }

        requests.cancel("k")
        #expect(!requests.isRunning("k"))

        let second = Task { try await requests.run("k") { await secondGate.wait(); return 2 } }
        try await waitUntil { requests.isRunning("k") }

        // The cancelled run finishes last; its cleanup must leave the replacement alone.
        firstGate.open()
        _ = try? await first.value
        #expect(requests.isRunning("k"))

        secondGate.open()
        #expect(try await second.value == 2)
        #expect(!requests.isRunning("k"))
    }

    @Test func `a cancelled run can see that it was superseded`() async throws {
        let requests = InFlightRequests<Int>()
        let gate = Gate()
        let wrote = Counter()

        // What the list loads do: check cancellation after the network call, before
        // writing, so a run replaced by a force refresh cannot clobber it.
        let first = Task {
            try await requests.run("k") {
                await gate.wait()
                try Task.checkCancellation()
                wrote.count += 1
                return 1
            }
        }
        try await waitUntil { requests.isRunning("k") }

        requests.cancel("k")
        gate.open()
        _ = try? await first.value

        #expect(wrote.count == 0)
    }

    @Test func `keys are independent`() async throws {
        let requests = InFlightRequests<Int>()
        let runs = Counter()

        let a = try await requests.run("a") { runs.count += 1; return runs.count }
        let b = try await requests.run("b") { runs.count += 1; return runs.count }

        #expect(a == 1)
        #expect(b == 2)
    }
}

// MARK: - Helpers

private struct TestFailure: Error {}

/// Mutable counter usable from the `@MainActor` operation closures.
@MainActor
private final class Counter {
    var count = 0
}

/// Suspends operations until the test decides to let them finish.
@MainActor
private final class Gate {
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

/// Yields until `condition` holds, so tests synchronise on state rather than sleeps.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 1000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition never became true")
}

/// Yields enough times for pending main-actor work to reach its next suspension.
@MainActor
private func settle() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}
