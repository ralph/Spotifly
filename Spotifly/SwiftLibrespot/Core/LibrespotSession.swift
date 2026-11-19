//
//  LibrespotSession.swift
//  SwiftLibrespot
//
//  Main session coordinator: dealer WebSocket and SPIRC.
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
/// Owns the two long-lived pieces of a session — the dealer WebSocket and the Spirc
/// controller — and forwards their events. Reconnection rebuilds both from the same
/// credentials.
///
/// There is no accesspoint: it was the built-in player's channel, for its login, the account
/// type that decided whether this Mac could stream, and the audio keys. The dealer and Spirc
/// need only the token, which also signs every other request, so the session works for any
/// account. Spotify's Soloist plays for this Mac (`SoloistEngine`).
public actor LibrespotSession {
    // MARK: - Properties

    public private(set) var state: SessionState = .disconnected

    public let deviceInfo: DeviceInfo

    /// What the session's requests are signed with, from the current or most recent login.
    /// Kept across disconnections so a reconnect does not need it handed in again, and
    /// cleared on logout via `forgetCredentials()`: it is the mark of a signed-in account,
    /// which a recovery must find before it reconnects.
    private var credentials: SpotifyCredentials?

    private var resolvedEndpoints: ResolvedEndpoints?
    private var dealerConnection: DealerConnection?
    private var spircController: SpircController?

    // MARK: - Events

    enum Event: Sendable {
        case state(SessionState)
        /// A cluster Spirc adopted, pushed by the dealer or returned by PutState.
        case cluster(SpircController.ClusterState)
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

    /// Connects the dealer and registers this device, signing the requests with
    /// `credentials`.
    func connect(signing credentials: SpotifyCredentials) async throws {
        self.credentials = credentials

        updateState(.connecting)

        do {
            resolvedEndpoints = try await APResolver().resolve()

            guard let dealerHost = resolvedEndpoints?.dealers.first else {
                throw LibrespotError.connectionFailed("No dealers available")
            }
            guard let spclientHost = resolvedEndpoints?.spclients.first else {
                throw LibrespotError.connectionFailed("No spclient hosts available")
            }

            updateState(.authenticating)

            dealerConnection = DealerConnection(
                endpoint: dealerHost,
                credentials: credentials,
                spclientHost: spclientHost,
                deviceId: deviceInfo.deviceId,
            )
            try await dealerConnection!.connect()

            // The dealer is the session: losing it means no cluster updates. A dead socket
            // must surface as a failed session, which is what arms the client's
            // auto-recovery; without this the session would go on looking healthy.
            await dealerConnection!.setCloseHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleTransportLost() }
            }

            spircController = SpircController(
                deviceInfo: deviceInfo,
                dealerConnection: dealerConnection!,
            )
            try await spircController!.initialize()
            setupSpircSubscriptions()

            updateState(.connected)
        } catch {
            updateState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Disconnects everything but remembers the credentials, so the client's
    /// recovery can `connect` again without them being handed in a second
    /// time — used around system sleep.
    public func disconnect() async {
        await spircController?.shutdown()
        await dealerConnection?.disconnect()

        spircController = nil
        dealerConnection = nil
        resolvedEndpoints = nil

        updateState(.disconnected)
    }

    /// Forgets credentials entirely — logout. A later recovery finds nothing
    /// to reconnect with rather than resurrecting a signed-out account.
    public func forgetCredentials() {
        credentials = nil
    }

    /// The dealer socket died on its own. Only a *connected* session reacts: a disconnect
    /// already in flight owns the transition.
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

    /// The credentials to reconnect with, while the account is signed in; see `credentials`.
    var currentCredentials: SpotifyCredentials? {
        credentials
    }

    /// The spclient host, where contexts are resolved.
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
    }
}
