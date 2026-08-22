//
//  InFlightRequests.swift
//  Spotifly
//
//  Single-flight registry for keyed async work.
//

import Foundation

/// Runs at most one operation per key at a time, and keeps it running when the
/// caller that started it goes away.
///
/// Both halves are load-bearing for the services built on this:
///
/// - **Deduplication.** A second caller for the same key awaits the task the first
///   one started rather than issuing a second request.
/// - **Cancellation resilience.** The task is unstructured, so it does not inherit
///   the caller's cancellation. SwiftUI cancels a view's `.task` whenever the view
///   is torn down — and the library detail views are torn down routinely, by
///   selection changes, section switches and the two/three-column flip — which
///   would otherwise abort the request in flight and leave the store empty with a
///   cancellation error on screen. Here the fetch runs to completion and writes to
///   `AppStore`; the view that replaces the cancelled one reads the result there.
///
/// A key must always stand for the same operation *and the same postcondition*.
/// Two operations that fetch different amounts of data may not share a key, or the
/// second caller silently receives the first one's smaller result.
@MainActor
final class InFlightRequests<Value: Sendable> {
    private var running: [String: (id: UUID, task: Task<Value, Error>)] = [:]

    /// Whether an operation for `key` is currently running.
    func isRunning(_ key: String) -> Bool {
        running[key] != nil
    }

    /// Runs `operation`, unless one is already running for `key` — in that case the
    /// existing run is awaited instead.
    ///
    /// A failure reaches every caller joined to the run, and the entry is dropped
    /// either way, so the next caller retries rather than inheriting the failure.
    func run(
        _ key: String,
        operation: @escaping @Sendable @MainActor () async throws -> Value,
    ) async throws -> Value {
        if let existing = running[key] {
            return try await existing.task.value
        }

        let id = UUID()
        let task = Task { @MainActor in
            // Identity check: a `cancel(_:)` may have replaced this entry while the
            // operation was running, and this run's cleanup must not drop its
            // successor.
            defer {
                if self.running[key]?.id == id {
                    self.running[key] = nil
                }
            }
            return try await operation()
        }
        running[key] = (id, task)

        return try await task.value
    }

    /// Cancels the run for `key` and drops it immediately, so the next
    /// `run(_:operation:)` starts fresh instead of joining the run it just
    /// cancelled.
    func cancel(_ key: String) {
        guard let entry = running.removeValue(forKey: key) else { return }
        entry.task.cancel()
    }
}

/// Whether an error is a cancellation rather than a failure worth showing.
///
/// Views use this to stay silent when their load was cancelled: the fetch itself
/// keeps running (see `InFlightRequests`) and its result lands in `AppStore`, so
/// showing the error would report a failure for work that is still on its way.
func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
