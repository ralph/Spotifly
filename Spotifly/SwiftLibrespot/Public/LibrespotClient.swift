//
//  LibrespotClient.swift
//  SwiftLibrespot
//
//  Public API for Swift librespot - replaces SpotifyPlayer stubs
//

import Combine
import Foundation

/// Main client for Swift librespot
/// This class provides the same API contract as SpotifyPlayer
/// and will eventually replace the stub implementations
public final class LibrespotClient: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = LibrespotClient()

    // MARK: - Properties

    private var session: LibrespotSession?
    private var audioPipeline: AudioPipeline?
    private var spclient: SPClient?
    private var subscriptions: Set<AnyCancellable> = []

    /// Device information
    private let deviceInfo: DeviceInfo

    /// Current connection state
    private var connectionState: LibrespotConnectionState?

    /// Cached position from audio pipeline
    private var cachedPositionMs: UInt32 = 0

    // MARK: - Publishers (matching SpotifyPlayer API)

    private let queueSubject = CurrentValueSubject<QueueState?, Never>(nil)
    private let playbackStateSubject = CurrentValueSubject<PlaybackState?, Never>(nil)
    private let volumeSubject = PassthroughSubject<UInt16, Never>()
    private let loadingSubject = PassthroughSubject<LoadingNotification, Never>()
    private let queueChangedSubject = PassthroughSubject<QueueChangedNotification, Never>()
    private let connectionStateSubject = CurrentValueSubject<LibrespotConnectionState?, Never>(nil)
    private let contextLoadedSubject = PassthroughSubject<ContextLoadedNotification, Never>()
    private let sessionDisconnectedSubject = PassthroughSubject<Void, Never>()
    private let sessionConnectedSubject = PassthroughSubject<Void, Never>()
    private let sessionClientChangedSubject = PassthroughSubject<SessionClientChangedNotification, Never>()

    // MARK: - Public Publishers

    var queue: AnyPublisher<QueueState?, Never> {
        queueSubject.eraseToAnyPublisher()
    }

    var playbackState: AnyPublisher<PlaybackState?, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    public var volumeChanged: AnyPublisher<UInt16, Never> {
        volumeSubject.eraseToAnyPublisher()
    }

    var loading: AnyPublisher<LoadingNotification, Never> {
        loadingSubject.eraseToAnyPublisher()
    }

    var queueChanged: AnyPublisher<QueueChangedNotification, Never> {
        queueChangedSubject.eraseToAnyPublisher()
    }

    var connectionStatePublisher: AnyPublisher<LibrespotConnectionState?, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    var contextLoaded: AnyPublisher<ContextLoadedNotification, Never> {
        contextLoadedSubject.eraseToAnyPublisher()
    }

    public var sessionDisconnected: AnyPublisher<Void, Never> {
        sessionDisconnectedSubject.eraseToAnyPublisher()
    }

    public var sessionConnected: AnyPublisher<Void, Never> {
        sessionConnectedSubject.eraseToAnyPublisher()
    }

    var sessionClientChanged: AnyPublisher<SessionClientChangedNotification, Never> {
        sessionClientChangedSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    private init() {
        deviceInfo = DeviceInfo.create(name: "Spotifly")
        debugLog("LibrespotClient", "Initialized with device: \(deviceInfo.deviceName) (\(deviceInfo.deviceId.prefix(8))...)")
    }

    // MARK: - Session Management

    /// Initialize with an access token
    public func initialize(accessToken: String) async throws {
        debugLog("LibrespotClient", "Initializing with access token...")

        // Store token for reconnection
        lastAccessToken = accessToken

        // Cancel any pending reconnect
        reconnectTask?.cancel()
        reconnectTask = nil

        // Create session
        session = LibrespotSession(deviceInfo: deviceInfo)

        // Subscribe to session state
        await subscribeToSessionEvents()

        // Connect
        try await session?.connect(accessToken: accessToken)

        // Get spclient host from session
        let spclientHost = await session?.spclientHost

        // Create SPClient for track metadata and CDN resolution
        spclient = SPClient(accessToken: accessToken, spclientHost: spclientHost)

        // Create audio pipeline with accesspoint and SPClient
        if let accesspoint = await session?.accesspoint {
            audioPipeline = AudioPipeline(
                accesspoint: accesspoint,
                accessToken: accessToken,
                spclientHost: spclientHost
            )

            // Start the audio engine
            await audioPipeline?.start()

            // Subscribe to audio pipeline events
            subscribeToAudioPipelineEvents()
        }

        // Update connection state
        updateConnectionState(connected: true)

        // Signal connected
        sessionConnectedSubject.send()

        debugLog("LibrespotClient", "Initialization complete")
    }

    /// Disconnect and cleanup
    public func cleanup() async {
        debugLog("LibrespotClient", "Cleaning up...")

        // Cancel any pending reconnect
        reconnectTask?.cancel()
        reconnectTask = nil

        await audioPipeline?.stop()
        await session?.disconnect()

        audioPipeline = nil
        spclient = nil
        session = nil
        subscriptions.removeAll()
        cachedPositionMs = 0
        hasEverConnected = false

        updateConnectionState(connected: false)
    }

    /// Soft cleanup (preserves playback)
    public func softCleanup() async {
        debugLog("LibrespotClient", "Soft cleanup...")
        // Keep audio playing, just disconnect control
        await session?.disconnect()
    }

    /// Shutdown and send goodbye
    public func shutdown() async {
        debugLog("LibrespotClient", "Shutting down...")
        await cleanup()
    }

    // MARK: - Reconnection

    /// Auto-reconnect state
    private var autoReconnectEnabled = true
    private var reconnectTask: Task<Void, Never>?
    private var lastAccessToken: String?
    /// Track if we've ever successfully connected (to avoid reconnect loops on initial connect)
    private var hasEverConnected = false

    /// Enable or disable auto-reconnection
    public func setAutoReconnect(_ enabled: Bool) {
        autoReconnectEnabled = enabled
        if !enabled {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    /// Attempt to reconnect with exponential backoff
    /// Uses the session's built-in reconnection logic
    public func reconnect() async throws {
        guard let session else {
            throw LibrespotError.notInitialized
        }

        debugLog("LibrespotClient", "Initiating reconnection...")
        try await session.reconnect()
    }

    /// Start auto-reconnect loop with the last used token
    private func startAutoReconnect() {
        guard autoReconnectEnabled, let token = lastAccessToken else {
            debugLog("LibrespotClient", "Auto-reconnect disabled or no token available")
            return
        }

        // Cancel any existing reconnect task
        reconnectTask?.cancel()

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            // Small delay before first attempt to avoid tight loops
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            do {
                // Try to reinitialize with the stored token
                try await initialize(accessToken: token)
                debugLog("LibrespotClient", "Auto-reconnect successful")
            } catch {
                debugLog("LibrespotClient", "Auto-reconnect failed: \(error)")
                // Session's reconnect already handles exponential backoff
            }
        }
    }

    // MARK: - Playback Control

    /// Play a URI (track, album, playlist)
    public func play(uri: String, positionMs: UInt32 = 0) async throws {
        debugLog("LibrespotClient", "Playing: \(uri)")

        guard session != nil else {
            throw LibrespotError.notInitialized
        }

        guard let audioPipeline else {
            throw LibrespotError.notInitialized
        }

        // Emit loading notification for fast UI update
        loadingSubject.send(LoadingNotification(trackUri: uri, positionMs: positionMs))

        // Start playback via audio pipeline
        do {
            try await audioPipeline.playTrack(uri: uri, positionMs: UInt64(positionMs))
        } catch {
            debugLog("LibrespotClient", "Playback error: \(error)")
            throw error
        }
    }

    /// Play multiple tracks
    public func playTracks(_ uris: [String]) async throws {
        guard let first = uris.first else { return }
        try await play(uri: first)
        // TODO: Queue remaining tracks via SPIRC
    }

    /// Pause playback
    public func pause() async {
        debugLog("LibrespotClient", "Pausing")
        await audioPipeline?.pause()
        updatePlaybackState(isPlaying: false, isPaused: true)
    }

    /// Resume playback
    public func resume() async {
        debugLog("LibrespotClient", "Resuming")
        await audioPipeline?.resume()
        updatePlaybackState(isPlaying: true, isPaused: false)
    }

    /// Stop playback
    public func stop() async {
        debugLog("LibrespotClient", "Stopping")
        await audioPipeline?.stop()
        updatePlaybackState(isPlaying: false, isPaused: false)
    }

    /// Seek to position
    public func seek(positionMs: UInt32) async throws {
        debugLog("LibrespotClient", "Seeking to \(positionMs)ms")
        try await audioPipeline?.seek(positionMs: UInt64(positionMs))
    }

    /// Skip to next track
    public func next() async throws {
        debugLog("LibrespotClient", "Next track")
        // TODO: Implement queue management
    }

    /// Skip to previous track
    public func previous() async throws {
        debugLog("LibrespotClient", "Previous track")
        // TODO: Implement queue management
    }

    /// Set volume (0.0 - 1.0)
    public func setVolume(_ volume: Double) async {
        let volumeFloat = Float(max(0, min(1, volume)))
        await audioPipeline?.setVolume(volumeFloat)
        volumeSubject.send(UInt16(volume * 65535))
    }

    /// Add to queue
    public func addToQueue(uri: String) async throws {
        debugLog("LibrespotClient", "Adding to queue: \(uri)")
        // TODO: Implement queue management
        queueChangedSubject.send(QueueChangedNotification(trackUri: uri))
    }

    /// Play radio
    public func playRadio(trackUri: String) async throws {
        debugLog("LibrespotClient", "Playing radio for: \(trackUri)")
        // TODO: Implement radio
    }

    // MARK: - Transfer

    /// Transfer playback to local (this device becomes active)
    public func transferToLocal() async throws {
        debugLog("LibrespotClient", "Transferring to local")

        guard let token = lastAccessToken else {
            throw LibrespotError.invalidState("Not authenticated")
        }

        guard let deviceId = connectionState?.deviceId else {
            throw LibrespotError.invalidState("Device ID not available")
        }

        // Use Web API to transfer playback to this device
        try await SpotifyAPI.transferPlayback(toDeviceId: deviceId, accessToken: token, play: true)
        debugLog("LibrespotClient", "Transfer to local complete")
    }

    /// Transfer playback to another device
    public func transferPlayback(toDeviceId deviceId: String) async throws {
        debugLog("LibrespotClient", "Transferring to device: \(deviceId)")

        guard let token = lastAccessToken else {
            throw LibrespotError.invalidState("Not authenticated")
        }

        // Use Web API to transfer playback to target device
        try await SpotifyAPI.transferPlayback(toDeviceId: deviceId, accessToken: token, play: true)
        debugLog("LibrespotClient", "Transfer complete")
    }

    // MARK: - State

    /// Whether session is connected
    public var isSessionConnected: Bool {
        session != nil && connectionState?.sessionConnected == true
    }

    /// Whether SPIRC is ready
    public var isSpircReady: Bool {
        connectionState?.spircReady == true
    }

    /// Whether currently playing
    public var isPlaying: Bool {
        playbackStateSubject.value?.isPlaying == true
    }

    /// Current position in milliseconds
    /// Note: This is a sync property, can't call actor method. Returns cached value.
    public var positionMs: UInt32 {
        cachedPositionMs
    }

    /// Get current connection state
    func getConnectionState() -> LibrespotConnectionState? {
        connectionState
    }

    // MARK: - Settings

    /// Set streaming bitrate
    func setBitrate(_: SpotifyPlayer.Bitrate) {
        // TODO: Store and apply on next track
    }

    /// Set gapless playback
    public func setGapless(_: Bool) {
        // TODO: Configure audio pipeline
    }

    // MARK: - Private

    private func subscribeToSessionEvents() async {
        guard let session else { return }

        // Clear any existing subscriptions before adding new ones
        subscriptions.removeAll()

        // Subscribe to session state changes
        // Use dropFirst to skip the initial .disconnected state that CurrentValueSubject emits
        session.statePublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.handleSessionStateChange(state)
                }
            }
            .store(in: &subscriptions)

        // Subscribe to SPIRC player state updates
        session.playerStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleSpircPlayerState(state)
            }
            .store(in: &subscriptions)

        // Subscribe to SPIRC cluster state updates
        session.clusterStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleSpircClusterState(state)
            }
            .store(in: &subscriptions)

        // Subscribe to SPIRC commands
        session.commandsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] command in
                self?.handleSpircCommand(command)
            }
            .store(in: &subscriptions)
    }

    /// Subscribe to audio pipeline events
    private func subscribeToAudioPipelineEvents() {
        guard let audioPipeline else { return }

        // Subscribe to playback state changes
        audioPipeline.playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleAudioPipelineState(state)
            }
            .store(in: &subscriptions)

        // Subscribe to position updates
        audioPipeline.position
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionMs in
                self?.cachedPositionMs = UInt32(positionMs)
            }
            .store(in: &subscriptions)

        // Subscribe to errors
        audioPipeline.errors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                debugLog("LibrespotClient", "Audio pipeline error: \(error)")
                self?.playbackStateSubject.send(PlaybackState(
                    isPlaying: false,
                    isPaused: false,
                    trackUri: self?.playbackStateSubject.value?.trackUri ?? "",
                    positionMs: 0,
                    durationMs: 0,
                    shuffle: false,
                    repeatTrack: false,
                    repeatContext: false
                ))
            }
            .store(in: &subscriptions)
    }

    /// Handle audio pipeline state changes
    private func handleAudioPipelineState(_ state: AudioPipeline.AudioPlaybackState) {
        switch state {
        case .idle:
            playbackStateSubject.send(nil)

        case let .loading(trackUri):
            loadingSubject.send(LoadingNotification(trackUri: trackUri, positionMs: 0))

        case let .playing(trackUri):
            let current = playbackStateSubject.value
            playbackStateSubject.send(PlaybackState(
                isPlaying: true,
                isPaused: false,
                trackUri: trackUri,
                positionMs: Int64(cachedPositionMs),
                durationMs: current?.durationMs ?? 0,
                shuffle: current?.shuffle ?? false,
                repeatTrack: current?.repeatTrack ?? false,
                repeatContext: current?.repeatContext ?? false
            ))

        case let .paused(trackUri):
            let current = playbackStateSubject.value
            playbackStateSubject.send(PlaybackState(
                isPlaying: false,
                isPaused: true,
                trackUri: trackUri,
                positionMs: Int64(cachedPositionMs),
                durationMs: current?.durationMs ?? 0,
                shuffle: current?.shuffle ?? false,
                repeatTrack: current?.repeatTrack ?? false,
                repeatContext: current?.repeatContext ?? false
            ))

        case let .buffering(trackUri):
            loadingSubject.send(LoadingNotification(trackUri: trackUri, positionMs: cachedPositionMs))

        case let .error(message):
            debugLog("LibrespotClient", "Playback error: \(message)")
        }
    }

    // MARK: - SPIRC Event Handlers

    private func handleSpircPlayerState(_ state: SpircController.SpircPlayerState?) {
        guard let state else {
            playbackStateSubject.send(nil)
            return
        }

        // Convert SpircPlayerState to PlaybackState
        let playbackState = PlaybackState(
            isPlaying: state.isPlaying,
            isPaused: state.isPaused,
            trackUri: state.trackUri ?? "",
            positionMs: Int64(state.positionMs),
            durationMs: Int64(state.durationMs),
            shuffle: state.shuffle,
            repeatTrack: state.repeatMode == .track,
            repeatContext: state.repeatMode == .context,
        )

        debugLog("LibrespotClient", "SPIRC player state: playing=\(playbackState.isPlaying), uri=\(playbackState.trackUri.prefix(50))")
        playbackStateSubject.send(playbackState)
    }

    private func handleSpircClusterState(_ state: SpircController.ClusterState?) {
        guard let state else { return }

        debugLog("LibrespotClient", "SPIRC cluster: \(state.devices.count) devices, active=\(state.activeDeviceId ?? "none")")

        // TODO: Emit device list updates if we add a devices publisher
    }

    private func handleSpircCommand(_ command: SpircCommand) {
        debugLog("LibrespotClient", "SPIRC command: \(command)")

        // Execute commands on audio pipeline via a Task
        Task { [weak self] in
            await self?.executeSpircCommand(command)
        }
    }

    /// Execute SPIRC command on audio pipeline
    private func executeSpircCommand(_ command: SpircCommand) async {
        switch command {
        case let .play(cmd):
            // Emit loading notification for fast UI update
            if let uri = cmd.trackUri ?? cmd.trackUris?.first {
                loadingSubject.send(LoadingNotification(
                    trackUri: uri,
                    positionMs: UInt32(cmd.positionMs ?? 0)
                ))

                // Start playback via audio pipeline
                do {
                    try await audioPipeline?.playTrack(uri: uri, positionMs: UInt64(cmd.positionMs ?? 0))
                } catch {
                    debugLog("LibrespotClient", "SPIRC play error: \(error)")
                }
            }

            // Also emit context loaded if we have a context
            if let contextUri = cmd.contextUri {
                let notification = ContextLoadedNotification(
                    contextUri: contextUri,
                    currentTrackUri: cmd.trackUri ?? cmd.trackUris?.first,
                    currentTrackProvider: "context",
                    nextTrackUris: [],
                    nextTrackProviders: [],
                    prevTrackUris: [],
                    prevTrackProviders: []
                )
                contextLoadedSubject.send(notification)
            }

        case .pause:
            await audioPipeline?.pause()

        case .resume:
            await audioPipeline?.resume()

        case let .seekTo(positionMs):
            try? await audioPipeline?.seek(positionMs: UInt64(positionMs))

        case .next:
            // TODO: Implement queue-based next track
            debugLog("LibrespotClient", "SPIRC next not yet implemented")

        case .prev:
            // TODO: Implement queue-based previous track
            debugLog("LibrespotClient", "SPIRC prev not yet implemented")

        case let .setVolume(volume):
            // Volume is 0-65535, convert to 0.0-1.0
            let normalizedVolume = Float(volume) / 65535.0
            await audioPipeline?.setVolume(normalizedVolume)
            volumeSubject.send(UInt16(volume))

        case let .addToQueue(uri):
            // TODO: Implement queue management
            queueChangedSubject.send(QueueChangedNotification(trackUri: uri))

        case let .setShuffle(enabled):
            // Update playback state with new shuffle value
            if let current = playbackStateSubject.value {
                let updated = PlaybackState(
                    isPlaying: current.isPlaying,
                    isPaused: current.isPaused,
                    trackUri: current.trackUri,
                    positionMs: current.positionMs,
                    durationMs: current.durationMs,
                    shuffle: enabled,
                    repeatTrack: current.repeatTrack,
                    repeatContext: current.repeatContext
                )
                playbackStateSubject.send(updated)
            }

        case let .setRepeat(mode):
            // Update playback state with new repeat value
            if let current = playbackStateSubject.value {
                let updated = PlaybackState(
                    isPlaying: current.isPlaying,
                    isPaused: current.isPaused,
                    trackUri: current.trackUri,
                    positionMs: current.positionMs,
                    durationMs: current.durationMs,
                    shuffle: current.shuffle,
                    repeatTrack: mode == .track,
                    repeatContext: mode == .context
                )
                playbackStateSubject.send(updated)
            }

        case .transfer:
            // Transfer command - session connected/disconnected events handle this
            break

        case .unknown:
            break
        }
    }

    private func handleSessionStateChange(_ state: SessionState) async {
        switch state {
        case .connected:
            hasEverConnected = true
            updateConnectionState(connected: true)
            sessionConnectedSubject.send()
        case .disconnected:
            updateConnectionState(connected: false)
            // Only emit disconnect and auto-reconnect if we were previously connected
            // This prevents spurious disconnect events during initial connection failures
            if hasEverConnected {
                sessionDisconnectedSubject.send()
                startAutoReconnect()
            }
        case let .failed(message):
            updateConnectionState(connected: false, error: message)
            // Only emit disconnect and auto-reconnect if we were previously connected
            if hasEverConnected {
                sessionDisconnectedSubject.send()
                startAutoReconnect()
            }
        case let .reconnecting(attempt):
            connectionState = LibrespotConnectionState(
                sessionConnected: false,
                sessionConnectionId: connectionState?.sessionConnectionId,
                spircReady: false,
                deviceId: deviceInfo.deviceId,
                deviceName: deviceInfo.deviceName,
                reconnectAttempt: UInt32(attempt),
                lastError: nil,
                connectedSinceMs: nil,
            )
            connectionStateSubject.send(connectionState)
        default:
            break
        }
    }

    private func updateConnectionState(connected: Bool, error: String? = nil) {
        connectionState = LibrespotConnectionState(
            sessionConnected: connected,
            sessionConnectionId: nil,
            spircReady: connected,
            deviceId: deviceInfo.deviceId,
            deviceName: deviceInfo.deviceName,
            reconnectAttempt: 0,
            lastError: error,
            connectedSinceMs: connected ? UInt64(Date().timeIntervalSince1970 * 1000) : nil,
        )
        connectionStateSubject.send(connectionState)
    }

    private func updatePlaybackState(isPlaying: Bool, isPaused: Bool) {
        let current = playbackStateSubject.value
        let newState = PlaybackState(
            isPlaying: isPlaying,
            isPaused: isPaused,
            trackUri: current?.trackUri ?? "",
            positionMs: current?.positionMs ?? 0,
            durationMs: current?.durationMs ?? 0,
            shuffle: current?.shuffle ?? false,
            repeatTrack: current?.repeatTrack ?? false,
            repeatContext: current?.repeatContext ?? false,
        )
        playbackStateSubject.send(newState)
    }
}
