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
    nonisolated func debugLog(_ module: String, _ message: String) {
        let timestamp = iso8601Formatter.string(from: Date())
        print("[\(timestamp) DEBUG \(module)] \(message)")
        fflush(stdout)
    }
#else
    @inlinable
    nonisolated func debugLog(_: String, _: String) {}
#endif
