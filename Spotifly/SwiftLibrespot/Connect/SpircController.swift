//
//  SpircController.swift
//  SwiftLibrespot
//
//  SPIRC state machine for Spotify Connect
//

import Combine
import Foundation

/// SPIRC controller for Spotify Connect protocol.
///
/// Registers this session's device, hidden and not a player, and keeps it on the cluster with
/// a heartbeat, so the cluster answers and is pushed to it: that is where the device list and
/// the playback shown come from. Spotify's Soloist plays for this Mac (`SoloistEngine`).
public actor SpircController {
    // MARK: - Properties

    private let deviceInfo: DeviceInfo
    private let dealerConnection: DealerConnection

    private var subscriptions: Set<AnyCancellable> = []

    /// Whether the controller reports to the cluster: from registration until the shutdown.
    public private(set) var isReady = false

    /// Heartbeat task; Spotify expects periodic PutState even without
    /// changes, and other clients drop devices that go quiet.
    private var heartbeatTask: Task<Void, Never>?

    /// How often state is republished while nothing happens.
    private static let heartbeatInterval: Duration = .seconds(30)

    /// The last PutState asked for, which the next one waits for.
    private var publishing: Task<Void, Never>?

    // MARK: - Publishers

    private nonisolated(unsafe) let clusterStateSubject = CurrentValueSubject<ClusterState?, Never>(nil)

    public nonisolated var clusterStatePublisher: AnyPublisher<ClusterState?, Never> {
        clusterStateSubject.eraseToAnyPublisher()
    }

    // MARK: - State Types

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
        dealerConnection: DealerConnection,
    ) {
        self.deviceInfo = deviceInfo
        self.dealerConnection = dealerConnection

        debugLog("SpircController", "Created for device: \(deviceInfo.deviceName)")
    }

    /// Initialize SPIRC controller and register with Spotify Connect
    public func initialize() async throws {
        debugLog("SpircController", "Initializing...")

        // Subscribe to dealer messages
        await setupDealerSubscriptions()

        // Register device with Spotify Connect. Non-fatal: a rejected or
        // stalled registration costs the device list and the playback shown,
        // which the next push brings.
        do {
            try await registerDevice()
        } catch {
            debugLog("SpircController", "Registration failed (continuing): \(error)")
        }

        startHeartbeat()

        isReady = true
        debugLog("SpircController", "SPIRC ready")
    }

    /// Stops reporting to Spotify Connect, ahead of the disconnect.
    public func shutdown() async {
        debugLog("SpircController", "Shutting down...")

        heartbeatTask?.cancel()
        heartbeatTask = nil

        isReady = false
        subscriptions.removeAll()
        dealerPushes?.cancel()
        dealerPushes = nil

        // No goodbye: Spotify answers a `becameInactive` PutState 422, and the
        // disconnect that follows already takes this device off Connect.
    }

    // MARK: - State Publishing

    /// Republishes our device state to the cluster, once the PutState before it has been
    /// answered: the heartbeat.
    ///
    /// One at a time, and each request is built only when it goes. PutStates are separate
    /// HTTP requests, and the cluster keeps whichever it handles last. librespot's Spirc
    /// awaits each PutState in its loop the same way.
    func publishState() async {
        let previous = publishing
        let next = Task {
            await previous?.value
            guard isReady else { return }
            await send(buildPutStateRequest())
        }
        publishing = next
        await next.value
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // A cancelled sleep ends the loop. It used to fall through to one
            // more heartbeat, which went out whenever the shutdown awaited
            // anything between cancelling it and clearing `isReady`.
            while await (try? Task.sleep(for: Self.heartbeatInterval)) != nil {
                await self?.publishState()
            }
        }
    }

    /// Puts our state and takes the cluster it is answered with as current.
    ///
    /// The answer is the whole cluster, and the dealer does not always push a change back, so
    /// every answer is adopted as a push would be.
    private func send(_ request: PutStateRequestProto) async {
        debugLog("SpircController", "PutState \(request.putStateReason) active=\(request.isActive)")
        do {
            if let cluster = try await dealerConnection.putState(request) {
                adopt(cluster)
            }
        } catch {
            debugLog("SpircController", "PutState failed: \(error)")
        }
    }

    // MARK: - Device Registration

    private func registerDevice() async throws {
        debugLog("SpircController", "Registering device...")

        let cluster = try await dealerConnection.putState(buildPutStateRequest())

        debugLog("SpircController", "Device registered")

        // Registration answers with the current cluster, and on a quiet account
        // it is the only time we are told: dealer pushes carry changes, so
        // without this the device list and the active device stayed empty until
        // somebody happened to press something elsewhere.
        if let cluster {
            adopt(cluster)
        }
    }

    /// A PutState for this device, never active: it plays nothing.
    private func buildPutStateRequest() -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = buildDevice()
        request.memberType = .connectState
        request.isActive = false
        request.putStateReason = .spircHello
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return request
    }

    /// The device half of a PutState: our identity and capabilities.
    ///
    /// Active-ness is *not* part of it — `ConnectDeviceInfo` has no such
    /// field; `PutStateRequest.is_active` is where the cluster reads it.
    func buildDevice() -> ConnectDevice {
        var deviceInfoProto = ConnectDeviceInfo()
        deviceInfoProto.canPlay = false
        deviceInfoProto.name = deviceInfo.deviceName
        deviceInfoProto.deviceId = deviceInfo.deviceId
        deviceInfoProto.deviceType = .computer
        deviceInfoProto.deviceSoftwareVersion = deviceInfo.softwareVersion
        deviceInfoProto.clientId = "65b708073fc0480ea92a077233ca87bd" // Spotify desktop client id
        deviceInfoProto.brand = deviceInfo.brandName
        deviceInfoProto.model = deviceInfo.modelName

        var caps = ConnectCapabilities()
        // It plays nothing, so it registers as the web player does when it cannot play:
        // hidden, so no device lists it as a speaker. The cluster still answers it and is
        // pushed to it, which is where the device list and the playback shown here come from.
        caps.canBePlayer = false
        caps.hidden = true
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
        return device
    }

    // MARK: - Dealer Subscriptions

    /// Hands the dealer's cluster pushes to this actor one at a time, in the order they
    /// arrived. They used to hop through the main actor on the way.
    private var dealerPushes: Task<Void, Never>?

    private func setupDealerSubscriptions() async {
        let (pushes, continuation) = AsyncStream.makeStream(of: ClusterUpdateProto.self)

        dealerConnection.clusterUpdates
            .sink { continuation.yield($0) }
            .store(in: &subscriptions)

        dealerPushes?.cancel()
        dealerPushes = Task { [weak self] in
            for await update in pushes {
                await self?.handleClusterUpdate(update)
            }
        }
    }

    private func handleClusterUpdate(_ update: ClusterUpdateProto) async {
        debugLog("SpircController", "Cluster update received")
        adopt(update.cluster)
    }

    /// Takes a cluster — pushed by the dealer or returned by PutState — as the
    /// current truth and publishes it.
    private func adopt(_ cluster: Cluster) {
        // A hidden device is one no device list offers as a speaker, as Spotify's own apps do
        // not: an idle web player, or a session registered as one that cannot play, as this
        // one does.
        let devices = cluster.devices.filter { !$0.value.capabilities.hidden }.map { deviceId, deviceInfoProto in
            ClusterState.ConnectedDevice(
                id: deviceId,
                name: deviceInfoProto.name,
                deviceType: SpotifyDeviceType(rawValue: Int(deviceInfoProto.deviceType.rawValue)) ?? .unknown,
                isActive: deviceId == cluster.activeDeviceId,
                volume: deviceInfoProto.volume,
                disableVolume: deviceInfoProto.capabilities.disableVolume,
            )
        }

        clusterStateSubject.send(ClusterState(
            activeDeviceId: cluster.activeDeviceId,
            devices: devices,
            timestamp: cluster.transferDataTimestamp,
            playerState: cluster.playerState,
        ))
    }
}
