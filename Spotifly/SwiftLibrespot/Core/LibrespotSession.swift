//
//  LibrespotSession.swift
//  SwiftLibrespot
//
//  Main session coordinator for Spotify connection
//

import Combine
import Foundation

/// Connection state for the Spotify session
public enum SessionState: Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

extension SessionState: Equatable {
    public nonisolated static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.authenticating, .authenticating),
             (.connected, .connected):
            true
        case let (.reconnecting(a), .reconnecting(b)):
            a == b
        case let (.failed(a), .failed(b)):
            a == b
        default:
            false
        }
    }
}

/// Main coordinator for Spotify connection
/// Manages AP connection, dealer WebSocket, and SPIRC controller
public actor LibrespotSession {
    // MARK: - Properties

    /// Current session state
    public private(set) var state: SessionState = .disconnected

    /// Device information for this session
    public let deviceInfo: DeviceInfo

    /// Current credentials
    private var credentials: SpotifyCredentials?

    /// AP resolver for endpoint discovery
    private var apResolver: APResolver?

    /// Accesspoint connection for protocol communication
    public private(set) var accesspoint: Accesspoint?

    /// Dealer WebSocket connection for SPIRC
    private var dealerConnection: DealerConnection?

    /// SPIRC controller for Spotify Connect
    private var spircController: SpircController?

    /// State publisher
    private nonisolated(unsafe) let stateSubject = CurrentValueSubject<SessionState, Never>(.disconnected)

    /// Connection ID from Spotify (used for state publishing)
    private var connectionId: String?

    // MARK: - Publishers

    /// Publisher for session state changes
    public nonisolated var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
        debugLog("LibrespotSession", "Session created for device: \(deviceInfo.deviceName)")
    }

    // MARK: - Connection Management

    /// Connect to Spotify with the given access token
    public func connect(accessToken: String) async throws {
        debugLog("LibrespotSession", "Connecting with access token...")
        credentials = SpotifyCredentials(accessToken: accessToken)

        await updateState(.connecting)

        do {
            // Step 1: Resolve AP endpoints
            apResolver = APResolver()
            let endpoints = try await apResolver!.resolve()
            debugLog("LibrespotSession", "Resolved \(endpoints.accesspoints.count) accesspoints, \(endpoints.dealers.count) dealers")

            // Step 2: Connect to Accesspoint
            guard let apEndpoint = endpoints.accesspoints.first else {
                throw LibrespotError.connectionFailed("No accesspoints available")
            }
            await updateState(.authenticating)

            accesspoint = Accesspoint(endpoint: apEndpoint)
            try await accesspoint!.connect(credentials: credentials!)
            debugLog("LibrespotSession", "Connected to accesspoint")

            // Step 3: Connect to Dealer
            guard let dealerEndpoint = endpoints.dealers.first else {
                throw LibrespotError.connectionFailed("No dealers available")
            }

            dealerConnection = DealerConnection(
                endpoint: dealerEndpoint,
                accessToken: accessToken,
            )
            try await dealerConnection!.connect()
            debugLog("LibrespotSession", "Connected to dealer")

            // Step 4: Initialize SPIRC controller
            spircController = SpircController(
                deviceInfo: deviceInfo,
                accesspoint: accesspoint!,
                dealerConnection: dealerConnection!,
            )
            try await spircController!.initialize()
            debugLog("LibrespotSession", "SPIRC controller initialized")

            await updateState(.connected)
            debugLog("LibrespotSession", "Session fully connected")

        } catch {
            await updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Disconnect from Spotify
    public func disconnect() async {
        debugLog("LibrespotSession", "Disconnecting...")

        await spircController?.shutdown()
        await dealerConnection?.disconnect()
        await accesspoint?.disconnect()

        spircController = nil
        dealerConnection = nil
        accesspoint = nil
        apResolver = nil
        credentials = nil
        connectionId = nil

        await updateState(.disconnected)
        debugLog("LibrespotSession", "Disconnected")
    }

    /// Attempt to reconnect with exponential backoff
    public func reconnect() async throws {
        guard let creds = credentials else {
            throw LibrespotError.notInitialized
        }

        var attempt = 1
        let maxAttempts = 10
        var delay: UInt64 = 1_000_000_000 // 1 second

        while attempt <= maxAttempts {
            await updateState(.reconnecting(attempt: attempt))
            debugLog("LibrespotSession", "Reconnection attempt \(attempt)/\(maxAttempts)")

            do {
                try await connect(accessToken: creds.accessToken)
                return
            } catch {
                debugLog("LibrespotSession", "Reconnection attempt \(attempt) failed: \(error)")
                attempt += 1
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 30_000_000_000) // Max 30 seconds
            }
        }

        throw LibrespotError.connectionFailed("Max reconnection attempts exceeded")
    }

    // MARK: - State Management

    private func updateState(_ newState: SessionState) {
        state = newState
        stateSubject.send(newState)
    }

    // MARK: - Session Info

    /// Whether the session is connected and ready
    public var isConnected: Bool {
        state == .connected
    }

    /// Whether SPIRC is ready for commands
    public var isSpircReady: Bool {
        get async {
            await spircController?.isReady ?? false
        }
    }

    /// Current connection ID
    public var currentConnectionId: String? {
        connectionId
    }
}
