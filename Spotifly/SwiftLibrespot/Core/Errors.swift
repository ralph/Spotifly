//
//  Errors.swift
//  SwiftLibrespot
//
//  Error types for the Swift librespot implementation
//

import Foundation

/// Errors that can occur during the Spotify Connect session
public enum LibrespotError: Error, LocalizedError, Sendable, Equatable {
    // MARK: - Connection Errors

    case connectionFailed(String)

    // MARK: - Request Errors

    /// A request the session makes to spclient was answered with an error, after its retries.
    case requestFailed(String, status: Int)

    // MARK: - SPIRC/Connect Errors

    case spircNotReady

    // MARK: - General Errors

    case notInitialized
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(message):
            "Connection failed: \(message)"
        case let .requestFailed(request, status):
            "\(request) failed: HTTP \(status)"
        case .spircNotReady:
            "SPIRC controller not ready"
        case .notInitialized:
            "Not initialized"
        case let .invalidState(message):
            "Invalid state: \(message)"
        }
    }
}
