//
//  DebugLog.swift
//  Spotifly
//
//  Debug logging utility with timestamps matching Rust's format.
//

import Foundation

#if DEBUG
    private nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Debug log with timestamp and module prefix.
    /// Format: [2026-01-17T21:39:06.964Z DEBUG ModuleName] message
    ///
    /// Writes to **stderr**, not stdout, and deliberately so. librespot's `env_logger`
    /// writes there too, so both halves of the app land in one stream in the order they
    /// happened — which is what makes a Rust event and the Swift callback it triggers
    /// readable as one sequence.
    ///
    /// The buffering matters more than the interleaving. stdout is block-buffered as soon
    /// as it is a pipe rather than a terminal, so `… | tee run.log` used to hold every
    /// Swift line until the app exited, while the Rust lines appeared live. A log that
    /// looks like Rust ran alone is worse than no log: it invites conclusions about code
    /// that simply had not been flushed yet. stderr is unbuffered, so this cannot recur.
    nonisolated func debugLog(_ module: String, _ message: String) {
        let timestamp = iso8601Formatter.string(from: Date())
        fputs("[\(timestamp) DEBUG \(module)] \(message)\n", stderr)
    }

    /// Short, stable identity for an object in the log.
    ///
    /// Enough to tell two instances apart at a glance without printing a full pointer.
    /// Used where a duplicate instance is the bug being watched for.
    nonisolated func storeTag(_ object: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(object).hashValue) % 1000)
    }
#else
    @inlinable
    nonisolated func debugLog(_: String, _: String) {}

    @inlinable
    nonisolated func storeTag(_: AnyObject) -> String {
        ""
    }
#endif
