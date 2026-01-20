//
//  Errors.swift
//  SwiftLibrespot
//
//  Error types for the Swift librespot implementation
//

import Foundation

/// Errors that can occur during Spotify connection and playback
public enum LibrespotError: Error, LocalizedError, Sendable {
    // MARK: - Connection Errors

    case connectionFailed(String)
    case authenticationFailed(String)
    case sessionExpired
    case networkUnavailable

    // MARK: - Protocol Errors

    case handshakeFailed(String)
    case invalidPacket(String)
    case encryptionError(String)
    case protobufError(String)

    // MARK: - Playback Errors

    case trackNotFound(String)
    case audioKeyFailed(String)
    case audioKeyError(Int)
    case decryptionFailed(String)
    case decodingFailed(String)
    case cdnError(String)

    // MARK: - SPIRC/Connect Errors

    case spircNotReady
    case deviceNotFound(String)
    case transferFailed(String)
    case commandFailed(String)

    // MARK: - General Errors

    case notInitialized
    case invalidState(String)
    case timeout(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(message):
            "Connection failed: \(message)"
        case let .authenticationFailed(message):
            "Authentication failed: \(message)"
        case .sessionExpired:
            "Session expired, please re-authenticate"
        case .networkUnavailable:
            "Network unavailable"
        case let .handshakeFailed(message):
            "Handshake failed: \(message)"
        case let .invalidPacket(message):
            "Invalid packet: \(message)"
        case let .encryptionError(message):
            "Encryption error: \(message)"
        case let .protobufError(message):
            "Protobuf error: \(message)"
        case let .trackNotFound(uri):
            "Track not found: \(uri)"
        case let .audioKeyFailed(message):
            "Failed to get audio key: \(message)"
        case let .audioKeyError(code):
            "Audio key error: \(code)"
        case let .decryptionFailed(message):
            "Decryption failed: \(message)"
        case let .decodingFailed(message):
            "Decoding failed: \(message)"
        case let .cdnError(message):
            "CDN error: \(message)"
        case .spircNotReady:
            "SPIRC controller not ready"
        case let .deviceNotFound(id):
            "Device not found: \(id)"
        case let .transferFailed(message):
            "Playback transfer failed: \(message)"
        case let .commandFailed(message):
            "Command failed: \(message)"
        case .notInitialized:
            "Not initialized"
        case let .invalidState(message):
            "Invalid state: \(message)"
        case let .timeout(message):
            "Timeout: \(message)"
        case let .unknown(message):
            "Unknown error: \(message)"
        }
    }
}
