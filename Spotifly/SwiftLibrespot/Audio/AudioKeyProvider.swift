//
//  AudioKeyProvider.swift
//  SwiftLibrespot
//
//  Fetches AES decryption keys from the accesspoint
//

import Foundation

/// Provides audio decryption keys for tracks
public actor AudioKeyProvider {
    // MARK: - Properties

    private let accesspoint: Accesspoint

    /// Cache of file ID -> audio key
    private var keyCache: [Data: Data] = [:]

    // MARK: - Initialization

    public init(accesspoint: Accesspoint) {
        self.accesspoint = accesspoint
    }

    // MARK: - Key Fetching

    /// Get the audio key for a track file
    public func getKey(fileId: Data, trackId: Data) async throws -> Data {
        // Check cache first
        if let cached = keyCache[fileId] {
            debugLog("AudioKeyProvider", "Key cache hit for file \(fileId.prefix(8).hexString)")
            return cached
        }

        debugLog("AudioKeyProvider", "Requesting key for file \(fileId.prefix(8).hexString)")

        // Request key from accesspoint
        let key = try await accesspoint.requestAudioKey(fileId: fileId, trackId: trackId)

        // Cache the key
        keyCache[fileId] = key

        debugLog("AudioKeyProvider", "Got key (\(key.count) bytes)")
        return key
    }
}

// MARK: - Data Extensions

extension Data {
    /// Hex string representation
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
