//
//  LibrespotSession.swift
//  SwiftLibrespot
//
//  Main session coordinator: accesspoint socket, dealer WebSocket, SPIRC.
//

import Combine
import Foundation

/// Connection state for the Spotify session
public nonisolated enum SessionState: Sendable, Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
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

    private var clientTokenProvider: (@Sendable () async throws -> String)?

    private var apResolver: APResolver?
    private var resolvedEndpoints: ResolvedEndpoints?
    public private(set) var accesspoint: Accesspoint?
    private var dealerConnection: DealerConnection?
    private var spircController: SpircController?

    // MARK: - Events

    enum Event: Sendable {
        case state(SessionState)
        /// A cluster Spirc adopted, pushed by the dealer or returned by PutState.
        case cluster(SpircController.ClusterState)
        case command(SpircRemoteCommand)
    }

    /// The session's states and what Spirc hears, for one consumer, in the
    /// order they happened. Starts with the state the session is created in.
    nonisolated let events: AsyncStream<Event>
    private nonisolated let eventSink: AsyncStream<Event>.Continuation

    // MARK: - Initialization

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        eventSink.yield(.state(state))
        debugLog("LibrespotSession", "Session created for device: \(deviceInfo.deviceName)")
    }

    deinit {
        eventSink.finish()
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

            guard let spclientHost = resolvedEndpoints?.spclients.first else {
                throw LibrespotError.connectionFailed("No spclient hosts available")
            }

            dealerConnection = DealerConnection(
                endpoint: dealerHost,
                tokenProvider: tokenProvider,
                spclientHost: spclientHost,
                deviceId: deviceInfo.deviceId,
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

    /// Disconnects everything but remembers the credentials, so the client's
    /// recovery can `connect` again without them being handed in a second
    /// time — used around system sleep.
    ///
    /// - Parameter stopped: what played here, for Spirc to report paused
    ///   before the disconnect; see `SpircController.shutdown(stopped:)`.
    public func disconnect(stopped: SpircController.SpircPlayerState? = nil) async {
        await spircController?.shutdown(stopped: stopped)
        await dealerConnection?.disconnect()
        await accesspoint?.disconnect()

        spircController = nil
        dealerConnection = nil
        accesspoint = nil
        apResolver = nil
        resolvedEndpoints = nil

        updateState(.disconnected)
    }

    /// Forgets credentials entirely — logout. A later recovery finds nothing
    /// to reconnect with rather than resurrecting a signed-out account.
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

    // MARK: - State Management

    private func updateState(_ newState: SessionState) {
        state = newState
        eventSink.yield(.state(newState))
    }

    // MARK: - Session Info

    public var isConnected: Bool {
        state == .connected
    }

    public var currentCredentials: APCredentials? {
        credentials
    }

    /// The accesspoint while the session is up; nil while it reconnects.
    var connectedAccesspoint: Accesspoint? {
        state == .connected ? accesspoint : nil
    }

    /// SPClient host for track metadata and CDN resolution
    public var spclientHost: String? {
        resolvedEndpoints?.spclients.first
    }

    // MARK: - SPIRC Events (forwarded from SpircController)

    private var spircSubscriptions: Set<AnyCancellable> = []

    /// Spirc sends synchronously from its own actor, so forwarding each value
    /// as it comes keeps Spirc's order. Its cluster subject replays the one
    /// that answered registration, which a quiet account never gets pushed.
    private func setupSpircSubscriptions() {
        spircSubscriptions.removeAll()
        guard let spirc = spircController else { return }

        spirc.clusterStatePublisher
            .compactMap(\.self)
            .sink { [eventSink] in eventSink.yield(.cluster($0)) }
            .store(in: &spircSubscriptions)

        spirc.commands
            .sink { [eventSink] in eventSink.yield(.command($0)) }
            .store(in: &spircSubscriptions)
    }

    // MARK: - Direct Access

    /// Forwards locally-produced playback state to Spirc so other devices see it.
    func reportLocalPlayerState(_ state: SpircController.SpircPlayerState?, active: Bool) async {
        await spircController?.updateLocalPlayerState(state, active: active)
    }

    /// Forwards the logical volume to Spirc, which reports it on this device.
    func reportLocalVolume(_ volume: UInt32) async {
        await spircController?.updateVolume(volume)
    }

    /// Tells Spirc whether this device still holds playback.
    func reportLocalActive(_ active: Bool) async {
        await spircController?.setActive(active)
    }
}
