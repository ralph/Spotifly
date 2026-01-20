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
    private var subscriptions: Set<AnyCancellable> = []

    /// Device information
    private let deviceInfo: DeviceInfo

    /// Current connection state
    private var connectionState: LibrespotConnectionState?

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

        // Create session
        session = LibrespotSession(deviceInfo: deviceInfo)

        // Subscribe to session state
        await subscribeToSessionEvents()

        // Connect
        try await session?.connect(accessToken: accessToken)

        // Create audio pipeline
        if let accesspoint = await session?.accesspoint {
            audioPipeline = AudioPipeline(accesspoint: accesspoint)
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

        await audioPipeline?.stop()
        await session?.disconnect()

        audioPipeline = nil
        session = nil
        subscriptions.removeAll()

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

    // MARK: - Playback Control

    /// Play a URI (track, album, playlist)
    public func play(uri: String) async throws {
        debugLog("LibrespotClient", "Playing: \(uri)")

        guard let session else {
            throw LibrespotError.notInitialized
        }

        // TODO: Resolve track metadata and file ID
        // TODO: Start audio pipeline

        loadingSubject.send(LoadingNotification(trackUri: uri, positionMs: 0))
    }

    /// Play multiple tracks
    public func playTracks(_ uris: [String]) async throws {
        guard let first = uris.first else { return }
        try await play(uri: first)
        // TODO: Queue remaining tracks
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

    /// Transfer playback to local
    public func transferToLocal() async throws {
        debugLog("LibrespotClient", "Transferring to local")
        // TODO: Implement transfer
    }

    /// Transfer playback to another device
    public func transferPlayback(toDeviceId deviceId: String) async throws {
        debugLog("LibrespotClient", "Transferring to device: \(deviceId)")
        // TODO: Implement transfer
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
        // TODO: Track position locally instead of querying actor
        0
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

        // Subscribe to session state changes
        session.statePublisher
            .sink { [weak self] state in
                Task { [weak self] in
                    await self?.handleSessionStateChange(state)
                }
            }
            .store(in: &subscriptions)
    }

    private func handleSessionStateChange(_ state: SessionState) async {
        switch state {
        case .connected:
            updateConnectionState(connected: true)
            sessionConnectedSubject.send()
        case .disconnected:
            updateConnectionState(connected: false)
            sessionDisconnectedSubject.send()
        case let .failed(message):
            updateConnectionState(connected: false, error: message)
            sessionDisconnectedSubject.send()
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
