//
//  LibrespotSession.swift
//  SwiftLibrespot
//
//  Main session coordinator: accesspoint socket, dealer WebSocket, SPIRC.
//

import Combine
import Foundation

/// Connection state for the Spotify session
public nonisolated enum SessionState: Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    public static func == (lhs: SessionState, rhs: SessionState) -> Bool {
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

/// Coordinator for one Spotify login.
///
/// Owns the three long-lived pieces of a session — accesspoint TCP (Shannon),
/// dealer WebSocket, and the Spirc controller — and forwards their events.
/// Reconnection rebuilds all three from the same credentials.
public actor LibrespotSession {
    // MARK: - Properties

    public private(set) var state: SessionState = .disconnected

    public let deviceInfo: DeviceInfo

    /// Credentials of the current or most recent login. Kept across
    /// disconnections so a reconnect does not need them handed in again;
    /// cleared on logout via `forgetCredentials()`.
    private var credentials: APCredentials?

    /// Produces fresh bearer tokens for HTTP endpoints. Required when the AP
    /// logged in with stored credentials, which carry no OAuth token; a token
    /// login can serve its own from `credentials`.
    private var tokenProvider: (@Sendable () async throws -> String)?
    private var clientTokenProvider: (@Sendable () async throws -> String)?

    private var apResolver: APResolver?
    private var resolvedEndpoints: ResolvedEndpoints?
    public private(set) var accesspoint: Accesspoint?
    private var dealerConnection: DealerConnection?
    private var spircController: SpircController?

    private nonisolated(unsafe) let stateSubject = CurrentValueSubject<SessionState, Never>(.disconnected)

    // MARK: - Publishers

    public nonisolated var statePublisher: AnyPublisher<SessionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
        debugLog("LibrespotSession", "Session created for device: \(deviceInfo.deviceName)")
    }

    // MARK: - Connection Management

    /// Connects with the given credentials and returns the server welcome,
    /// whose reusable credentials are worth persisting.
    @discardableResult
    public func connect(
        credentials: APCredentials,
        tokenProvider: @escaping @Sendable () async throws -> String,
        clientTokenProvider: (@Sendable () async throws -> String)? = nil,
    ) async throws -> APWelcome {
        self.credentials = credentials
        self.tokenProvider = tokenProvider
        self.clientTokenProvider = clientTokenProvider

        updateState(.connecting)

        do {
            // Resolve endpoints and pre-generate DH keys concurrently — key
            // generation is pure CPU, resolution is network-bound.
            apResolver = APResolver()
            async let resolveTask = apResolver!.resolve()

            let dh = try? DiffieHellman()
            resolvedEndpoints = try await resolveTask

            guard let dealerHost = resolvedEndpoints?.dealers.first else {
                throw LibrespotError.connectionFailed("No dealers available")
            }

            updateState(.authenticating)

            // Rotate through the resolved accesspoints: servers drop
            // handshakes they dislike (rate limits, transient resets), and
            // the next one usually answers.
            var welcome: APWelcome?
            var lastError: Error = LibrespotError.connectionFailed("No accesspoints available")
            for apEndpoint in resolvedEndpoints?.accesspoints.prefix(4) ?? [] {
                let candidate = Accesspoint(endpoint: apEndpoint, preGeneratedDH: dh)
                do {
                    welcome = try await candidate.connect(credentials: credentials, deviceId: deviceInfo.deviceId)
                    accesspoint = candidate
                    break
                } catch {
                    debugLog("LibrespotSession", "AP \(apEndpoint) failed: \(error.localizedDescription)")
                    lastError = error
                    await candidate.disconnect()
                }
            }
            guard let welcome else { throw lastError }

            // A dead socket must surface as a failed session, which is what
            // arms the client's auto-recovery; without this the receive loop
            // would exit silently and the UI would keep routing commands into
            // a corpse.
            await accesspoint!.setCloseHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleTransportLost() }
            }

            dealerConnection = await DealerConnection(
                endpoint: dealerHost,
                accessToken: bearerToken(),
            )
            if let clientTokenProvider {
                await dealerConnection!.setClientTokenProvider(clientTokenProvider)
            }
            try await dealerConnection!.connect()

            // The dealer is the other half of the session, and losing it is
            // just as fatal: no cluster updates, no remote commands. Treated
            // exactly like an accesspoint loss so one recovery path covers both.
            await dealerConnection!.setCloseHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleTransportLost() }
            }

            spircController = SpircController(
                deviceInfo: deviceInfo,
                accesspoint: accesspoint!,
                dealerConnection: dealerConnection!,
            )
            try await spircController!.initialize()
            setupSpircSubscriptions()

            updateState(.connected)
            return welcome
        } catch {
            updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Disconnects everything but remembers the credentials, so
    /// `reconnect()` can bring the session back — used around system sleep.
    public func disconnect() async {
        await spircController?.shutdown()
        await dealerConnection?.disconnect()
        await accesspoint?.disconnect()

        spircController = nil
        dealerConnection = nil
        accesspoint = nil
        apResolver = nil
        resolvedEndpoints = nil

        updateState(.disconnected)
    }

    /// Forgets credentials entirely — logout. A subsequent `reconnect` fails
    /// rather than resurrecting a signed-out account.
    public func forgetCredentials() {
        credentials = nil
    }

    /// The accesspoint socket died on its own. Only a *connected* session
    /// reacts: a disconnect already in flight owns the transition.
    func handleTransportLost() {
        guard state == .connected else { return }
        debugLog("LibrespotSession", "Transport lost")
        updateState(.failed("Connection lost"))
        Task { [weak self] in await self?.disconnect() }
    }

    /// Rebuilds the session from remembered credentials with backoff.
    public func reconnect() async throws {
        guard let credentials else {
            throw LibrespotError.notInitialized
        }
        guard let tokenProvider else {
            throw LibrespotError.notInitialized
        }

        var attempt = 1
        let maxAttempts = 10
        var delay: Duration = .seconds(1)

        while attempt <= maxAttempts {
            updateState(.reconnecting(attempt: attempt))
            debugLog("LibrespotSession", "Reconnection attempt \(attempt)/\(maxAttempts)")

            do {
                try await connect(credentials: credentials, tokenProvider: tokenProvider)
                return
            } catch {
                debugLog("LibrespotSession", "Reconnection attempt \(attempt) failed: \(error)")
                attempt += 1
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
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

    public var isConnected: Bool {
        state == .connected
    }

    public var currentCredentials: APCredentials? {
        credentials
    }

    /// SPClient host for track metadata and CDN resolution
    public var spclientHost: String? {
        resolvedEndpoints?.spclients.first
    }

    /// Bearer token for HTTP endpoints: the login's own token when it has
    /// one, otherwise a fresh one from the provider.
    private func bearerToken() async -> String {
        if let token = credentials?.accessToken {
            return token
        }
        return await (try? tokenProvider?()) ?? ""
    }

    // MARK: - SPIRC Publishers (forwarded from SpircController)

    public nonisolated var playerStatePublisher: AnyPublisher<SpircController.SpircPlayerState?, Never> {
        spircPlayerStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var clusterStatePublisher: AnyPublisher<SpircController.ClusterState?, Never> {
        spircClusterStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commandsPublisher: AnyPublisher<SpircRemoteCommand, Never> {
        spircCommandSubject.eraseToAnyPublisher()
    }

    private nonisolated(unsafe) let spircPlayerStateSubject = CurrentValueSubject<SpircController.SpircPlayerState?, Never>(nil)
    private nonisolated(unsafe) let spircClusterStateSubject = CurrentValueSubject<SpircController.ClusterState?, Never>(nil)
    private nonisolated(unsafe) let spircCommandSubject = PassthroughSubject<SpircRemoteCommand, Never>()

    private var spircSubscriptions: Set<AnyCancellable> = []

    private func setupSpircSubscriptions() {
        spircSubscriptions.removeAll()
        guard let spirc = spircController else { return }

        spirc.playerStatePublisher
            .sink { [weak self] state in
                self?.spircPlayerStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        spirc.clusterStatePublisher
            .sink { [weak self] state in
                self?.spircClusterStateSubject.send(state)
            }
            .store(in: &spircSubscriptions)

        spirc.commands
            .sink { [weak self] command in
                self?.spircCommandSubject.send(command)
            }
            .store(in: &spircSubscriptions)
    }

    // MARK: - Direct Access

    func performShutdown() async {
        await spircController?.shutdown()
        await dealerConnection?.disconnect()
        await accesspoint?.disconnect()
        updateState(.disconnected)
    }

    /// Forwards locally-produced playback state to Spirc so other devices see it.
    func reportLocalPlayerState(_ state: SpircController.SpircPlayerState?, active: Bool) async {
        await spircController?.updateLocalPlayerState(state, active: active)
    }

    /// Forwards the logical volume to Spirc, which reports it on this device.
    func reportLocalVolume(_ volume: UInt32) async {
        await spircController?.updateVolume(volume)
    }
}
