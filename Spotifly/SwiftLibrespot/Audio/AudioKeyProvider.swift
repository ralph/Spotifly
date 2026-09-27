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

    /// The session's accesspoint while it is connected, and nil while it
    /// reconnects, which replaces the socket.
    private let accesspoint: @Sendable () async -> Accesspoint?

    /// How long a request waits for a reconnect. A reset is usually back
    /// within 1.3 s, but one waited 5 s for a refused port first.
    private static let reconnectWait: Duration = .seconds(15)

    /// Cache of file ID -> audio key
    private var keyCache: [Data: Data] = [:]

    // MARK: - Initialization

    public init(accesspoint: @escaping @Sendable () async -> Accesspoint?) {
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

        let key: Data
        do {
            key = try await connectedAccesspoint().requestAudioKey(fileId: fileId, trackId: trackId)
        } catch LibrespotError.connectionFailed, LibrespotError.notInitialized {
            // The socket died under the request; the reconnect brings another.
            debugLog("AudioKeyProvider", "Key request lost with the connection; asking again")
            key = try await connectedAccesspoint().requestAudioKey(fileId: fileId, trackId: trackId)
        }

        // Cache the key
        keyCache[fileId] = key

        debugLog("AudioKeyProvider", "Got key (\(key.count) bytes)")
        return key
    }

    /// The accesspoint to ask, once there is one. A track needed while the
    /// session reconnects — a press of Next, auto-advance, the fetch-ahead —
    /// waits for it, rather than failing on the socket it replaces and leaving
    /// nothing loaded once the session is back.
    private func connectedAccesspoint() async throws -> Accesspoint {
        let deadline = ContinuousClock.now + Self.reconnectWait
        while true {
            if let accesspoint = await accesspoint() {
                return accesspoint
            }
            guard ContinuousClock.now < deadline else {
                throw LibrespotError.connectionFailed("No connection to ask for the audio key")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Hex string representation
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
