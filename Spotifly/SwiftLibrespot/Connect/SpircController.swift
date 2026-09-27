//
//  SpircController.swift
//  SwiftLibrespot
//
//  SPIRC state machine for Spotify Connect
//

import Combine
import Foundation

/// SPIRC controller for Spotify Connect protocol
/// Handles device registration, command processing, and state publishing
public actor SpircController {
    // MARK: - Properties

    private let deviceInfo: DeviceInfo
    private let accesspoint: Accesspoint
    private let dealerConnection: DealerConnection

    private var playerState: SpircPlayerState?
    private var subscriptions: Set<AnyCancellable> = []

    /// Whether the controller is ready for commands
    public private(set) var isReady = false

    /// The last command received, named the way its sender looks for its
    /// acknowledgement: by message id *and* by the device that sent it,
    /// both echoed in every PutState (librespot's `set_last_command`).
    private var lastCommand: (messageId: UInt32, sentBy: String)?

    /// Whether this device believes it is the active one, and the moment it
    /// became so. Both are reflected into every PutState.
    ///
    /// `activeSince` is stamped **once**, when the device becomes active, and
    /// re-sent unchanged afterwards — that is what `started_playing_at` means
    /// (librespot's `ConnectState::set_active` / `set_now`). Re-stamping it to
    /// `now` on every heartbeat told the backend this device had only just
    /// started playing, which is where a device transferring playback away
    /// resumed from: the beginning of the track.
    private var isActive = false
    private var activeSince: UInt64?

    /// Logical Connect volume (0…65535) this device reports. Other clients
    /// render their slider from it, so a hard-coded value pins every remote
    /// view of this Mac at that number no matter what it is really playing at.
    private var volume: UInt32 = 65535 / 2

    /// Heartbeat task; Spotify expects periodic PutState even without
    /// changes, and other clients drop devices that go quiet.
    private var heartbeatTask: Task<Void, Never>?

    /// How often state is republished while nothing happens.
    private static let heartbeatInterval: Duration = .seconds(30)

    // MARK: - Publishers

    private nonisolated(unsafe) let clusterStateSubject = CurrentValueSubject<ClusterState?, Never>(nil)
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircRemoteCommand, Never>()

    public nonisolated var clusterStatePublisher: AnyPublisher<ClusterState?, Never> {
        clusterStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commands: AnyPublisher<SpircRemoteCommand, Never> {
        commandSubject.eraseToAnyPublisher()
    }

    // MARK: - State Types

    public struct SpircPlayerState: Sendable {
        public var isPlaying: Bool
        public var isPaused: Bool
        public var trackUri: String?
        public var positionMs: UInt64
        public var durationMs: UInt64
        public var shuffle: Bool
        public var repeatMode: SpircRepeatMode
        public var timestamp: UInt64
        /// The context playing, and where the track sits in it. Another device
        /// taking over resolves the same context and continues from there.
        public var contextUri: String
        public var contextIndex: Int?
        /// "context", or "queue" for a track the user queued.
        public var trackProvider: String
        /// What plays next — queued tracks first — and what played before,
        /// oldest first. A transfer hands both to the receiving device.
        public var nextTracks: [(uri: String, provider: String)]
        public var previousTracks: [(uri: String, provider: String)]

        public enum SpircRepeatMode: Sendable, Equatable {
            case off
            case context
            case track
        }
    }

    public struct ClusterState: Sendable {
        public let activeDeviceId: String?
        public let devices: [ConnectedDevice]
        public let timestamp: UInt64
        /// What the active device is playing, as it last reported it.
        public let playerState: PlayerState?

        public struct ConnectedDevice: Sendable, Identifiable {
            public let id: String
            public let name: String
            public let deviceType: SpotifyDeviceType
            public let isActive: Bool
            public let volume: UInt32
            /// The device says it takes no volume commands. Speakers hides its
            /// slider on this, so dropping it drew a control that does nothing.
            public let disableVolume: Bool
        }
    }

    // MARK: - Initialization

    public init(
        deviceInfo: DeviceInfo,
        accesspoint: Accesspoint,
        dealerConnection: DealerConnection,
    ) {
        self.deviceInfo = deviceInfo
        self.accesspoint = accesspoint
        self.dealerConnection = dealerConnection

        debugLog("SpircController", "Created for device: \(deviceInfo.deviceName)")
    }

    /// Initialize SPIRC controller and register with Spotify Connect
    public func initialize() async throws {
        debugLog("SpircController", "Initializing...")

        // Subscribe to dealer messages
        await setupDealerSubscriptions()

        // Register device with Spotify Connect. Non-fatal: a rejected or
        // stalled registration costs Connect visibility, not playback.
        do {
            try await registerDevice()
        } catch {
            debugLog("SpircController", "Registration failed (continuing): \(error)")
        }

        startHeartbeat()

        isReady = true
        debugLog("SpircController", "SPIRC ready")
    }

    /// Shutdown and unregister from Spotify Connect
    public func shutdown() async {
        debugLog("SpircController", "Shutting down...")

        heartbeatTask?.cancel()
        heartbeatTask = nil
        isReady = false
        subscriptions.removeAll()

        // Tell the cluster this device is going away. Best effort: a dead
        // socket must not block shutdown.
        var goodbye = PutStateRequestProto()
        goodbye.memberType = .connectState
        goodbye.putStateReason = .becameInactive
        goodbye.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        goodbye.device = buildDevice(playerState: nil)
        _ = try? await dealerConnection.putState(goodbye)
    }

    // MARK: - State Publishing

    /// Republishes our device/player state to the cluster.
    ///
    /// - Parameter reason: why the state moved; nil means routine heartbeat.
    func publishState(reason: PutStateReason?) async {
        guard isReady else { return }

        var request = buildPutStateRequest(isActive: isActive)
        if let reason {
            request.putStateReason = reason
        }
        await send(request)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                await self?.publishState(reason: nil)
            }
        }
    }

    /// Adopts the logical volume and tells the cluster about it.
    func updateVolume(_ volume: UInt32) async {
        guard self.volume != volume else { return }
        self.volume = volume
        await publishState(reason: .volumeChanged)
    }

    /// Adopts locally-produced playback state and republishes it, so other
    /// devices see what this one plays.
    ///
    /// - Parameters:
    ///   - state: the current player state, or nil once nothing is playing.
    ///   - active: true when local playback just started, which marks this
    ///     device active in the cluster.
    public func updateLocalPlayerState(_ state: SpircPlayerState?, active: Bool) async {
        let becameActive = active && !isActive
        playerState = state
        if active {
            setActive(true)
        }

        guard isReady else { return }

        var request = buildPutStateRequest(isActive: isActive)
        request.putStateReason = becameActive ? .newDevice : (state != nil ? .playerStateChanged : .spircNotify)
        await send(request)
    }

    /// Puts our state and takes the cluster it is answered with as current.
    ///
    /// The answer is the whole cluster, and it is the only reliable way to
    /// learn that our own report made this device the active one: the dealer
    /// does not always push that change back. With a web player handing
    /// playback here, no push named this device in two and a half minutes of
    /// playing — so the app never knew it was active, did not stop when the
    /// web player took playback back, and routed its own transport buttons to
    /// the device that had let go.
    private func send(_ request: PutStateRequestProto) async {
        do {
            if let cluster = try await dealerConnection.putState(request) {
                adopt(cluster)
            }
        } catch {
            debugLog("SpircController", "PutState failed: \(error)")
        }
    }

    /// Takes or gives up the active role, mirroring librespot's
    /// `ConnectState::set_active`.
    ///
    /// Standing down matters as much as standing up: this used to be
    /// `isActive = isActive || active`, which could only ever latch on. Once
    /// another device took playback, every heartbeat went on asserting
    /// `is_active` for this one — and a few seconds later the cluster handed
    /// playback straight back to it.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }

        isActive = active
        activeSince = active ? UInt64(Date().timeIntervalSince1970 * 1000) : nil
    }

    // MARK: - Device Registration

    private func registerDevice() async throws {
        debugLog("SpircController", "Registering device...")

        let request = buildPutStateRequest(isActive: false)
        let cluster = try await dealerConnection.putState(request)

        debugLog("SpircController", "Device registered")

        // Registration answers with the current cluster, and on a quiet account
        // it is the only time we are told: dealer pushes carry changes, so
        // without this the device list and the active device stayed empty until
        // somebody happened to press something elsewhere.
        if let cluster {
            adopt(cluster)
        }
    }

    private func buildPutStateRequest(isActive: Bool) -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = buildDevice(playerState: playerState)
        request.memberType = .connectState
        request.isActive = isActive
        request.putStateReason = isActive ? .newDevice : .spircHello
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        if let activeSince {
            request.startedPlayingAt = activeSince
        }

        if let lastCommand {
            request.lastCommandMessageId = lastCommand.messageId
            request.lastCommandSentByDeviceId = lastCommand.sentBy
        }

        return request
    }

    /// The device half of a PutState: our identity, capabilities, and current
    /// player state if we have one.
    ///
    /// Active-ness is *not* part of it — `ConnectDeviceInfo` has no such
    /// field; `PutStateRequest.is_active` is where the cluster reads it.
    private func buildDevice(playerState: SpircPlayerState?) -> ConnectDevice {
        var deviceInfoProto = ConnectDeviceInfo()
        deviceInfoProto.canPlay = deviceInfo.supportsPlayback
        deviceInfoProto.volume = volume
        deviceInfoProto.name = deviceInfo.deviceName
        deviceInfoProto.deviceId = deviceInfo.deviceId
        deviceInfoProto.deviceType = .computer
        deviceInfoProto.deviceSoftwareVersion = deviceInfo.softwareVersion
        deviceInfoProto.clientId = "65b708073fc0480ea92a077233ca87bd" // Spotify desktop client id
        deviceInfoProto.brand = deviceInfo.brandName
        deviceInfoProto.model = deviceInfo.modelName

        var caps = ConnectCapabilities()
        caps.canBePlayer = deviceInfo.supportsPlayback
        caps.isObservable = true
        caps.volumeSteps = 64
        caps.supportedTypes = ["audio/track", "audio/episode"]
        caps.commandAcks = true
        caps.supportsGzipPushes = true
        caps.supportsTransferCommand = true
        caps.supportsCommandRequest = true
        deviceInfoProto.capabilities = caps

        var device = ConnectDevice()
        device.deviceInfo = deviceInfoProto

        if let ps = playerState {
            var playerStateProto = PlayerState()
            playerStateProto.timestamp = Int64(ps.timestamp)
            playerStateProto.positionAsOfTimestamp = Int64(ps.positionMs)
            playerStateProto.duration = Int64(ps.durationMs)
            // The rate the position advances at. Without it the backend treats
            // the position as frozen where it was reported, so a transfer away
            // handed the next device the start of the track.
            playerStateProto.playbackSpeed = ps.isPaused ? 0 : 1
            playerStateProto.isPaused = ps.isPaused
            // librespot's `set_status`: desktop and mobile clients grey out
            // their play button for a paused device unless all three are set.
            playerStateProto.isPlaying = ps.isPlaying || ps.isPaused
            playerStateProto.isBuffering = ps.isPaused

            if let uri = ps.trackUri {
                playerStateProto.track = ProvidedTrack(uri: uri, provider: ps.trackProvider)
            }
            playerStateProto.contextUri = ps.contextUri
            if !ps.contextUri.isEmpty {
                playerStateProto.contextUrl = "context://\(ps.contextUri)"
            }
            if let index = ps.contextIndex {
                playerStateProto.index = ContextIndex(page: 0, track: UInt32(index))
            }
            playerStateProto.nextTracks = ps.nextTracks.map { ProvidedTrack(uri: $0.uri, provider: $0.provider) }
            playerStateProto.prevTracks = ps.previousTracks.map { ProvidedTrack(uri: $0.uri, provider: $0.provider) }

            var options = ContextPlayerOptions()
            options.shufflingContext = ps.shuffle
            options.repeatingContext = ps.repeatMode == .context
            options.repeatingTrack = ps.repeatMode == .track
            playerStateProto.options = options

            device.playerState = playerStateProto
        }

        return device
    }

    // MARK: - Dealer Subscriptions

    private func setupDealerSubscriptions() async {
        // Subscribe to cluster updates
        dealerConnection.clusterUpdates
            .sink { [weak self] update in
                Task { @MainActor [weak self] in
                    await self?.handleClusterUpdate(update)
                }
            }
            .store(in: &subscriptions)

        // Subscribe to commands
        dealerConnection.commands
            .sink { [weak self] command in
                Task { @MainActor [weak self] in
                    await self?.handleCommand(command)
                }
            }
            .store(in: &subscriptions)
    }

    private func handleClusterUpdate(_ update: ClusterUpdateProto) async {
        debugLog("SpircController", "Cluster update received")
        adopt(update.cluster)
    }

    /// Takes a cluster — pushed by the dealer or returned by PutState — as the
    /// current truth and publishes it.
    private func adopt(_ cluster: Cluster) {
        let devices = cluster.devices.map { deviceId, deviceInfoProto in
            ClusterState.ConnectedDevice(
                id: deviceId,
                name: deviceInfoProto.name,
                deviceType: SpotifyDeviceType(rawValue: Int(deviceInfoProto.deviceType.rawValue)) ?? .unknown,
                isActive: deviceId == cluster.activeDeviceId,
                volume: deviceInfoProto.volume,
                disableVolume: deviceInfoProto.capabilities.disableVolume,
            )
        }

        // The cluster's player state is only ever *read* here. When this device
        // is the active one it is our own report echoed back, already stale;
        // adopting it as our state used to put that echo into the next heartbeat.
        clusterStateSubject.send(ClusterState(
            activeDeviceId: cluster.activeDeviceId,
            devices: devices,
            timestamp: cluster.transferDataTimestamp,
            playerState: cluster.playerState,
        ))
    }

    private func handleCommand(_ envelope: SpircRemoteCommand) async {
        debugLog("SpircController", "Command received: \(envelope.command) (message \(envelope.messageId.map(String.init) ?? "-") from \(envelope.sentByDeviceId ?? "-"))")
        if let messageId = envelope.messageId {
            // Acknowledged by the PutState that follows handling it. The id
            // alone was not enough: a web player sending to this device logged
            // every command as `ack_timeout`.
            lastCommand = (messageId, envelope.sentByDeviceId ?? "")
        }

        // Forwarding is the whole job. LibrespotClient executes the command
        // and reports the result back through updateLocalPlayerState, which
        // is the state this device publishes. A second, optimistic copy used
        // to be maintained here and overwritten moments later by the real one.
        commandSubject.send(envelope)
    }
}
