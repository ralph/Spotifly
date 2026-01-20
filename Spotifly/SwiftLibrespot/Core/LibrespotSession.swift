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

    /// Cached resolved endpoints
    private var resolvedEndpoints: ResolvedEndpoints?

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
            resolvedEndpoints = try await apResolver!.resolve()
            debugLog("LibrespotSession", "Resolved \(resolvedEndpoints!.accesspoints.count) accesspoints, \(resolvedEndpoints!.dealers.count) dealers")

            // Step 2: Connect to Accesspoint
            guard let apEndpoint = resolvedEndpoints?.accesspoints.first else {
                throw LibrespotError.connectionFailed("No accesspoints available")
            }
            await updateState(.authenticating)

            accesspoint = Accesspoint(endpoint: apEndpoint)
            try await accesspoint!.connect(credentials: credentials!)
            debugLog("LibrespotSession", "Connected to accesspoint")

            // Step 3: Connect to Dealer
            guard let dealerHost = resolvedEndpoints?.dealers.first else {
                throw LibrespotError.connectionFailed("No dealers available")
            }

            dealerConnection = DealerConnection(
                endpoint: dealerHost,
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
            setupSpircSubscriptions()
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

    /// Dealer endpoint for direct connection info
    public var dealerEndpoint: String? {
        // Return the endpoint that was used for dealer connection
        resolvedEndpoints?.dealers.first
    }

    // MARK: - SPIRC Publishers (forwarded from SpircController)

    /// Player state updates from SPIRC
    public nonisolated var playerStatePublisher: AnyPublisher<SpircController.SpircPlayerState?, Never> {
        spircPlayerStateSubject.eraseToAnyPublisher()
    }

    /// Cluster state updates from SPIRC
    public nonisolated var clusterStatePublisher: AnyPublisher<SpircController.ClusterState?, Never> {
        spircClusterStateSubject.eraseToAnyPublisher()
    }

    /// SPIRC commands from remote devices
    public nonisolated var commandsPublisher: AnyPublisher<SpircCommand, Never> {
        spircCommandSubject.eraseToAnyPublisher()
    }

    // Internal subjects for SPIRC events
    private nonisolated(unsafe) let spircPlayerStateSubject = CurrentValueSubject<SpircController.SpircPlayerState?, Never>(nil)
    private nonisolated(unsafe) let spircClusterStateSubject = CurrentValueSubject<SpircController.ClusterState?, Never>(nil)
    private nonisolated(unsafe) let spircCommandSubject = PassthroughSubject<SpircCommand, Never>()

    /// Subscriptions for SPIRC controller
    private var spircSubscriptions: Set<AnyCancellable> = []

    /// Setup subscriptions to SPIRC controller publishers
    private func setupSpircSubscriptions() {
        spircSubscriptions.removeAll()

        guard let spirc = spircController else { return }

        // Forward player state
        spirc.playerStatePublisher
            .sink { [weak self] state in
                self?.spircPlayerStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        // Forward cluster state
        spirc.clusterStatePublisher
            .sink { [weak self] state in
                self?.spircClusterStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        // Forward commands
        spirc.commands
            .sink { [weak self] command in
                self?.spircCommandSubject.send(command)
            }
            .store(in: &spircSubscriptions)
    }
}
