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
    case authenticationFailed(String)
    /// The accesspoint refused the login because the account is not Premium.
    case premiumRequired

    // MARK: - Protocol Errors

    case handshakeFailed(String)
    case encryptionError(String)
    case macMismatch
    case audioKeyError(Int)

    // MARK: - Request Errors

    /// A request the session makes to spclient was answered with an error, after its retries.
    case requestFailed(String, status: Int)

    // MARK: - SPIRC/Connect Errors

    case spircNotReady

    // MARK: - General Errors

    case notInitialized
    case invalidState(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(message):
            "Connection failed: \(message)"
        case let .authenticationFailed(message):
            "Authentication failed: \(message)"
        case .premiumRequired:
            String(localized: "playback.needs_premium")
        case let .handshakeFailed(message):
            "Handshake failed: \(message)"
        case let .encryptionError(message):
            "Encryption error: \(message)"
        case .macMismatch:
            "MAC verification failed"
        case let .audioKeyError(code):
            "Audio key error: \(code)"
        case let .requestFailed(request, status):
            "\(request) failed: HTTP \(status)"
        case .spircNotReady:
            "SPIRC controller not ready"
        case .notInitialized:
            "Not initialized"
        case let .invalidState(message):
            "Invalid state: \(message)"
        case let .timeout(message):
            "Timeout: \(message)"
        }
    }
}
