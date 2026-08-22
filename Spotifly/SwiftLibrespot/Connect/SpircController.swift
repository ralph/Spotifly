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
    private var clusterState: ClusterState?
    private var subscriptions: Set<AnyCancellable> = []

    /// Whether the controller is ready for commands
    public private(set) var isReady = false

    /// Last command message ID (for acknowledgment)
    private var lastCommandMessageId: UInt64?

    /// Whether this device believes it is the active one. Reflected into
    /// every PutState.
    private var isActive = false

    /// Heartbeat task; Spotify expects periodic PutState even without
    /// changes, and other clients drop devices that go quiet.
    private var heartbeatTask: Task<Void, Never>?

    /// How often state is republished while nothing happens.
    private static let heartbeatInterval: Duration = .seconds(30)

    // MARK: - Publishers

    private nonisolated(unsafe) let playerStateSubject = CurrentValueSubject<SpircPlayerState?, Never>(nil)
    private nonisolated(unsafe) let clusterStateSubject = CurrentValueSubject<ClusterState?, Never>(nil)
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircRemoteCommand, Never>()

    public nonisolated var playerStatePublisher: AnyPublisher<SpircPlayerState?, Never> {
        playerStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var clusterStatePublisher: AnyPublisher<ClusterState?, Never> {
        clusterStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commands: AnyPublisher<SpircRemoteCommand, Never> {
        commandSubject.eraseToAnyPublisher()
    }

    // MARK: - State Types

    public struct SpircPlayerState: Sendable, Equatable {
        public var isPlaying: Bool
        public var isPaused: Bool
        public var trackUri: String?
        public var positionMs: UInt64
        public var durationMs: UInt64
        public var shuffle: Bool
        public var repeatMode: SpircRepeatMode
        public var timestamp: UInt64

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

        public struct ConnectedDevice: Sendable, Identifiable {
            public let id: String
            public let name: String
            public let deviceType: SpotifyDeviceType
            public let isActive: Bool
            public let volume: UInt32
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

        // Register device with Spotify Connect
        try await registerDevice()

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
        goodbye.device = Self.buildDevice(deviceInfo: deviceInfo, isActive: false, playerState: nil)
        try? await dealerConnection.putState(goodbye)
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
        do {
            try await dealerConnection.putState(request)
        } catch {
            debugLog("SpircController", "PutState failed: \(error)")
        }
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
        isActive = isActive || active

        guard isReady else { return }

        var request = buildPutStateRequest(isActive: isActive)
        request.putStateReason = becameActive ? .newDevice : (state != nil ? .playerStateChanged : .spircNotify)
        try? await dealerConnection.putState(request)
    }

    // MARK: - Device Registration

    private func registerDevice() async throws {
        debugLog("SpircController", "Registering device...")

        let request = buildPutStateRequest(isActive: false)
        try await dealerConnection.putState(request)

        debugLog("SpircController", "Device registered")
    }

    private func buildPutStateRequest(isActive: Bool) -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = Self.buildDevice(deviceInfo: deviceInfo, isActive: isActive, playerState: playerState)
        request.memberType = .connectState
        request.isActive = isActive
        request.putStateReason = isActive ? .newDevice : .spircHello
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)

        if isActive {
            request.startedPlayingAt = UInt64(Date().timeIntervalSince1970 * 1000)
        }

        if let msgId = lastCommandMessageId {
            request.lastCommandMessageId = UInt32(msgId)
        }

        return request
    }

    /// The device half of a PutState: our identity, capabilities, and current
    /// player state if we have one.
    private static func buildDevice(
        deviceInfo: DeviceInfo,
        isActive: Bool,
        playerState: SpircPlayerState?,
    ) -> ConnectDevice {
        var deviceInfoProto = ConnectDeviceInfo()
        deviceInfoProto.canPlay = deviceInfo.supportsPlayback
        deviceInfoProto.volume = 65535 / 2 // 50%
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
            playerStateProto.isPaused = ps.isPaused
            playerStateProto.isPlaying = ps.isPlaying

            if let uri = ps.trackUri {
                var track = ProvidedTrack()
                track.uri = uri
                track.provider = "context"
                playerStateProto.track = track
            }

            var options = ContextPlayerOptions()
            options.shufflingContext = ps.shuffle
            options.repeatingContext = ps.repeatMode == .context
            options.repeatingTrack = ps.repeatMode == .track
            playerStateProto.options = options

            device.playerState = playerStateProto
        }

        _ = isActive
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

        // Update cluster state from parsed proto
        let cluster = update.cluster
        let devices = cluster.devices.map { deviceId, deviceInfoProto in
            ClusterState.ConnectedDevice(
                id: deviceId,
                name: deviceInfoProto.name,
                deviceType: SpotifyDeviceType(rawValue: Int(deviceInfoProto.deviceType.rawValue)) ?? .unknown,
                isActive: deviceId == cluster.activeDeviceId,
                volume: deviceInfoProto.volume,
            )
        }

        clusterState = ClusterState(
            activeDeviceId: cluster.activeDeviceId,
            devices: devices,
            timestamp: cluster.transferDataTimestamp,
        )
        clusterStateSubject.send(clusterState)

        // Update player state if this device is active
        if let ps = cluster.playerState,
           cluster.activeDeviceId == deviceInfo.deviceId
        {
            playerState = SpircPlayerState(
                isPlaying: ps.isPlaying,
                isPaused: ps.isPaused,
                trackUri: ps.track?.uri,
                positionMs: UInt64(bitPattern: ps.positionAsOfTimestamp),
                durationMs: UInt64(bitPattern: ps.duration),
                shuffle: ps.options.shufflingContext,
                repeatMode: convertFromProtoOptions(ps.options),
                timestamp: UInt64(bitPattern: ps.timestamp),
            )
            playerStateSubject.send(playerState)
        }
    }

    private func convertFromProtoOptions(_ options: ContextPlayerOptions) -> SpircPlayerState.SpircRepeatMode {
        if options.repeatingTrack {
            .track
        } else if options.repeatingContext {
            .context
        } else {
            .off
        }
    }

    private func handleCommand(_ envelope: SpircRemoteCommand) async {
        debugLog("SpircController", "Command received: \(envelope.command)")
        if let messageId = envelope.messageId {
            // Acknowledged in the next PutState via last_command_message_id.
            lastCommandMessageId = UInt64(messageId)
        }
        commandSubject.send(envelope)

        // Handle command locally
        switch envelope.command {
        case let .play(playCmd):
            await handlePlayCommand(playCmd)
        case .pause:
            await handlePauseCommand()
        case .resume:
            await handleResumeCommand()
        case let .seekTo(position):
            await handleSeekCommand(positionMs: position)
        case .next:
            await handleNextCommand()
        case .prev:
            await handlePreviousCommand()
        case let .setVolume(volume):
            await handleVolumeCommand(volume)
        case let .setShuffle(enabled):
            await handleShuffleCommand(enabled)
        case let .setRepeat(mode):
            await handleRepeatCommand(mode)
        case let .transfer(transferCmd):
            await handleTransferCommand(transferCmd)
        case let .addToQueue(uri):
            await handleAddToQueueCommand(uri)
        case .unknown:
            break
        }
    }

    // MARK: - Command Handlers

    private func handlePlayCommand(_ cmd: SpircCommand.PlayCommand) async {
        debugLog("SpircController", "Play: \(cmd.contextUri ?? cmd.trackUri ?? "?")")
        playerState?.isPlaying = true
        playerState?.isPaused = false
        playerState?.trackUri = cmd.trackUri ?? cmd.trackUris?.first
        playerState?.positionMs = cmd.positionMs ?? 0
        playerStateSubject.send(playerState)
    }

    private func handlePauseCommand() async {
        debugLog("SpircController", "Pause")
        playerState?.isPlaying = false
        playerState?.isPaused = true
        playerStateSubject.send(playerState)
    }

    private func handleResumeCommand() async {
        debugLog("SpircController", "Resume")
        playerState?.isPlaying = true
        playerState?.isPaused = false
        playerStateSubject.send(playerState)
    }

    private func handleSeekCommand(positionMs: UInt64) async {
        debugLog("SpircController", "Seek to \(positionMs)ms")
        playerState?.positionMs = positionMs
        playerStateSubject.send(playerState)
    }

    private func handleNextCommand() async {
        debugLog("SpircController", "Next track")
        // TODO: Implement queue management
    }

    private func handlePreviousCommand() async {
        debugLog("SpircController", "Previous track")
        // TODO: Implement queue management
    }

    private func handleVolumeCommand(_ volume: UInt32) async {
        debugLog("SpircController", "Volume: \(volume)")
        // TODO: Update volume state
    }

    private func handleShuffleCommand(_ enabled: Bool) async {
        debugLog("SpircController", "Shuffle: \(enabled)")
        playerState?.shuffle = enabled
        playerStateSubject.send(playerState)
    }

    private func handleRepeatCommand(_ mode: ClusterUpdate.RepeatMode) async {
        debugLog("SpircController", "Repeat: \(mode)")
        // Convert from ClusterUpdate.RepeatMode to SpircPlayerState.SpircRepeatMode
        let spircMode: SpircPlayerState.SpircRepeatMode = switch mode {
        case .off: .off
        case .context: .context
        case .track: .track
        }
        playerState?.repeatMode = spircMode
        playerStateSubject.send(playerState)
    }

    private func handleTransferCommand(_ cmd: SpircCommand.TransferCommand) async {
        debugLog("SpircController", "Transfer to: \(cmd.targetDeviceId)")
        // TODO: Implement playback transfer
    }

    private func handleAddToQueueCommand(_ uri: String) async {
        debugLog("SpircController", "Add to queue: \(uri)")
        // TODO: Implement queue management
    }

    // MARK: - Outgoing Commands

    /// Play a track or context
    public func play(uri: String, positionMs _: UInt64 = 0) async throws {
        debugLog("SpircController", "Playing: \(uri)")
        // TODO: Send play command via accesspoint
    }

    /// Pause playback
    public func pause() async throws {
        debugLog("SpircController", "Pausing")
        // TODO: Send pause command
    }

    /// Resume playback
    public func resume() async throws {
        debugLog("SpircController", "Resuming")
        // TODO: Send resume command
    }

    /// Seek to position
    public func seek(positionMs: UInt64) async throws {
        debugLog("SpircController", "Seeking to \(positionMs)ms")
        // TODO: Send seek command
    }

    /// Transfer playback to this device
    public func transferToLocal() async throws {
        debugLog("SpircController", "Transferring to local")
        // TODO: Implement transfer
    }

    /// Transfer playback to another device
    public func transferPlayback(toDeviceId deviceId: String) async throws {
        debugLog("SpircController", "Transferring to \(deviceId)")
        // TODO: Implement transfer
    }
}
