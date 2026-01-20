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

    private var playerState: PlayerState?
    private var clusterState: ClusterState?
    private var subscriptions: Set<AnyCancellable> = []

    /// Whether the controller is ready for commands
    public private(set) var isReady = false

    /// Last command message ID (for acknowledgment)
    private var lastCommandMessageId: UInt64?

    // MARK: - Publishers

    private nonisolated(unsafe) let playerStateSubject = CurrentValueSubject<PlayerState?, Never>(nil)
    private nonisolated(unsafe) let clusterStateSubject = CurrentValueSubject<ClusterState?, Never>(nil)
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircCommand, Never>()

    public nonisolated var playerStatePublisher: AnyPublisher<PlayerState?, Never> {
        playerStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var clusterStatePublisher: AnyPublisher<ClusterState?, Never> {
        clusterStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commands: AnyPublisher<SpircCommand, Never> {
        commandSubject.eraseToAnyPublisher()
    }

    // MARK: - State Types

    public struct PlayerState: Sendable, Equatable {
        public var isPlaying: Bool
        public var isPaused: Bool
        public var trackUri: String?
        public var positionMs: UInt64
        public var durationMs: UInt64
        public var shuffle: Bool
        public var repeatMode: RepeatMode
        public var timestamp: UInt64

        public enum RepeatMode: Sendable, Equatable {
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

        isReady = true
        debugLog("SpircController", "SPIRC ready")
    }

    /// Shutdown and unregister from Spotify Connect
    public func shutdown() async {
        debugLog("SpircController", "Shutting down...")

        isReady = false
        subscriptions.removeAll()

        // Send goodbye to other devices
        // TODO: Implement goodbye message
    }

    // MARK: - Device Registration

    private func registerDevice() async throws {
        debugLog("SpircController", "Registering device...")

        let request = buildPutStateRequest(isActive: false)
        try await dealerConnection.putState(request)

        debugLog("SpircController", "Device registered")
    }

    private func buildPutStateRequest(isActive: Bool) -> PutStateRequest {
        let deviceInfoState = PutStateRequest.PutStateDeviceInfo(
            canPlay: deviceInfo.supportsPlayback,
            volume: 65535 / 2, // 50%
            name: deviceInfo.deviceName,
            deviceId: deviceInfo.deviceId,
            deviceType: "COMPUTER",
            deviceSoftwareVersion: deviceInfo.softwareVersion,
            clientId: "spotifly",
            brand: deviceInfo.brandName,
            model: deviceInfo.modelName,
            capabilities: PutStateRequest.PutStateCapabilities(
                canBePlayer: deviceInfo.supportsPlayback,
                gaplessTrack: deviceInfo.supportsGapless,
                supportsLogout: false,
                isObservable: true,
                volumeSteps: 64,
                supportedTypes: ["audio/track", "audio/episode"],
                commandAcks: true,
            ),
        )

        var playerStateProto: PutStateRequest.PutStatePlayerState?
        if let ps = playerState {
            playerStateProto = PutStateRequest.PutStatePlayerState(
                timestamp: ps.timestamp,
                positionAsOfTimestamp: ps.positionMs,
                isPaused: ps.isPaused,
                isPlaying: ps.isPlaying,
                track: ps.trackUri.map { uri in
                    ClusterUpdate.TrackProto(uri: uri, uid: nil, metadata: nil, provider: "context")
                },
                contextUri: nil,
                shuffle: ps.shuffle,
                repeatMode: convertRepeatMode(ps.repeatMode),
                nextTracks: [],
                prevTracks: [],
            )
        }

        return PutStateRequest(
            memberType: "CONNECT_STATE",
            device: PutStateRequest.PutStateDevice(
                deviceInfo: deviceInfoState,
                playerState: playerStateProto,
            ),
            isActive: isActive,
            startedPlayingAt: isActive ? UInt64(Date().timeIntervalSince1970 * 1000) : nil,
            lastCommandMessageId: lastCommandMessageId,
            lastCommandSentByDeviceId: nil,
        )
    }

    private func convertRepeatMode(_ mode: PlayerState.RepeatMode) -> ClusterUpdate.RepeatMode {
        switch mode {
        case .off: .off
        case .context: .context
        case .track: .track
        }
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

    private func handleClusterUpdate(_ update: ClusterUpdate) async {
        debugLog("SpircController", "Cluster update received")

        // Update cluster state
        let devices = update.cluster.devices.map { device in
            ClusterState.ConnectedDevice(
                id: device.deviceId,
                name: device.deviceName,
                deviceType: SpotifyDeviceType(rawValue: Int(device.deviceType) ?? 0) ?? .unknown,
                isActive: device.isActive,
                volume: device.volume,
            )
        }

        clusterState = ClusterState(
            activeDeviceId: update.cluster.activeDeviceId,
            devices: devices,
            timestamp: update.cluster.transferDataTimestamp ?? UInt64(Date().timeIntervalSince1970 * 1000),
        )
        clusterStateSubject.send(clusterState)

        // Update player state if this device is active
        if let ps = update.cluster.playerState,
           update.cluster.activeDeviceId == deviceInfo.deviceId
        {
            playerState = PlayerState(
                isPlaying: ps.isPlaying,
                isPaused: ps.isPaused,
                trackUri: ps.track?.uri,
                positionMs: ps.positionAsOfTimestamp,
                durationMs: ps.track?.metadata?.durationMs ?? 0,
                shuffle: ps.shuffle,
                repeatMode: convertFromClusterRepeatMode(ps.repeatMode),
                timestamp: ps.timestamp,
            )
            playerStateSubject.send(playerState)
        }
    }

    private func convertFromClusterRepeatMode(_ mode: ClusterUpdate.RepeatMode) -> PlayerState.RepeatMode {
        switch mode {
        case .off: .off
        case .context: .context
        case .track: .track
        }
    }

    private func handleCommand(_ command: SpircCommand) async {
        debugLog("SpircController", "Command received: \(command)")
        commandSubject.send(command)

        // Handle command locally
        switch command {
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
        playerState?.repeatMode = convertFromClusterRepeatMode(mode)
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
