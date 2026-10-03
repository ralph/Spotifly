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
    /// Registered with the one the session was given, which a new session
    /// otherwise started at half.
    private var volume: UInt32

    /// Heartbeat task; Spotify expects periodic PutState even without
    /// changes, and other clients drop devices that go quiet.
    private var heartbeatTask: Task<Void, Never>?

    /// How often state is republished while nothing happens.
    private static let heartbeatInterval: Duration = .seconds(30)

    /// The last PutState asked for, which the next one waits for.
    private var publishing: Task<Void, Never>?

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
        /// The resolver's metadata of the context, sent as `context_metadata`.
        public var contextMetadata: [String: String] = [:]
        /// What the context does not allow, as the resolver named it: a station's shuffle and
        /// repeat. Sent as the context's restrictions and the player's, as go-librespot sends
        /// them, for other devices to grey those controls.
        public var restrictions = Restrictions()
        public var contextIndex: Int?
        /// The station autoplay's rows came from, told with each of them.
        public var autoplayContextUri: String?
        /// "context", or "queue" for a track the user queued.
        public var trackProvider: String
        /// The current row's uid, where it has one.
        public var trackUid: String?
        /// The context row the session stands on (`PlaybackQueue.sessionRow`).
        var sessionRow: QueueItem?
        /// What plays next — queued tracks first — and what played before,
        /// oldest first. A transfer hands both to the receiving device. Each row's uid names
        /// it, so another device can name one copy of a track apart from another.
        var nextTracks: [QueueItem]
        var previousTracks: [QueueItem]

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
        volume: UInt32,
    ) {
        self.deviceInfo = deviceInfo
        self.accesspoint = accesspoint
        self.dealerConnection = dealerConnection
        self.volume = volume

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

    /// Stops reporting to Spotify Connect, ahead of the disconnect.
    ///
    /// - Parameter stopped: what played here, which a deliberate disconnect
    ///   reports paused where it had got to, as librespot's
    ///   `handle_disconnect` does. Spotify hears the position only when the
    ///   state changes, so it would keep the last report, often the track's
    ///   start and still "playing", and whatever mirrors it next would show
    ///   that. Nil when the transport died: the track plays on from memory,
    ///   and the recovery reports it.
    public func shutdown(stopped: SpircPlayerState? = nil) async {
        debugLog("SpircController", "Shutting down...")

        heartbeatTask?.cancel()
        heartbeatTask = nil

        await reportStopped(stopped)

        isReady = false
        subscriptions.removeAll()
        dealerPushes?.cancel()
        dealerPushes = nil

        // No goodbye: Spotify answers a `becameInactive` PutState 422, and the
        // disconnect that follows already takes this device off Connect.
    }

    /// Lets go of playback that stopped here, over an error or at a context's end: reports
    /// where it stopped while still the active device, as `shutdown(stopped:)` does, then
    /// stands down. Nil reports nothing first.
    func release(stopped: SpircPlayerState?) async {
        await reportStopped(stopped)
        setActive(false)
    }

    /// Reports `state` paused where it had got to; nothing when there is none.
    private func reportStopped(_ state: SpircPlayerState?) async {
        guard let state else { return }
        playerState = Self.stopped(state, atMs: UInt64(Date().timeIntervalSince1970 * 1000))
        await publishState(reason: .playerStateChanged)
    }

    /// `state` paused at `nowMs`: its position run on to then, if it was playing, and no
    /// further than the track's end.
    static func stopped(_ state: SpircPlayerState, atMs nowMs: UInt64) -> SpircPlayerState {
        var state = state
        let elapsed = state.isPlaying && nowMs > state.timestamp ? nowMs - state.timestamp : 0
        state.positionMs = state.durationMs > 0 ? min(state.positionMs + elapsed, state.durationMs) : state.positionMs + elapsed
        state.isPlaying = false
        state.isPaused = true
        state.timestamp = nowMs
        return state
    }

    // MARK: - State Publishing

    /// Republishes our device/player state to the cluster, once the PutState
    /// before it has been answered.
    ///
    /// One at a time, and each request is built only when it goes. PutStates
    /// are separate HTTP requests, and the cluster keeps whichever it handles
    /// last: a heartbeat still in flight when a pause was reported could land
    /// after it, and other devices saw this one playing until the next
    /// heartbeat. librespot's Spirc awaits each PutState in its loop the same
    /// way.
    ///
    /// - Parameter reason: why the state moved; nil means routine heartbeat.
    func publishState(reason: PutStateReason?) async {
        let previous = publishing
        let next = Task {
            await previous?.value
            guard isReady else { return }

            var request = buildPutStateRequest(isActive: isActive)
            if let reason {
                request.putStateReason = reason
            }
            await send(request)
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

        await publishState(reason: becameActive ? .newDevice : (state != nil ? .playerStateChanged : .spircNotify))
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
        let player = request.device.playerState.map {
            "\($0.isPaused ? "paused" : "playing") \($0.positionAsOfTimestamp)ms@\($0.timestamp)"
        }
        debugLog("SpircController", "PutState \(request.putStateReason) active=\(request.isActive): \(player ?? "no player state")")
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
        request.device = buildDevice()
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
    func buildDevice() -> ConnectDevice {
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
        // A device that cannot play registers as the web player does then: hidden, so no
        // device lists it as a speaker. The cluster still answers it and is pushed to it,
        // which is where the device list and the playback shown here come from.
        caps.hidden = !deviceInfo.supportsPlayback
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
                playerStateProto.track = Self.provided(uri: uri, uid: ps.trackUid, provider: ps.trackProvider, context: ps.contextUri, station: ps.autoplayContextUri)
            }
            playerStateProto.contextUri = ps.contextUri
            playerStateProto.contextMetadata = ps.contextMetadata
            playerStateProto.contextRestrictions = ps.restrictions
            playerStateProto.restrictions = ps.restrictions
            if !ps.contextUri.isEmpty {
                playerStateProto.contextUrl = "context://\(ps.contextUri)"
            }
            if let index = ps.contextIndex {
                playerStateProto.index = ContextIndex(page: 0, track: UInt32(index))
            }
            let provided: (QueueItem) -> ProvidedTrack = { item in
                var track = Self.provided(uri: item.uri, uid: item.uid, provider: item.provider, context: ps.contextUri, station: ps.autoplayContextUri)
                track.isHidden = item.hidden
                return track
            }
            playerStateProto.nextTracks = ps.nextTracks.map(provided)
            playerStateProto.queueRevision = Self.queueRevision(of: ps.nextTracks.map(\.uri))
            playerStateProto.prevTracks = ps.previousTracks.map(provided)

            var options = ContextPlayerOptions()
            options.shufflingContext = ps.shuffle
            options.repeatingContext = ps.repeatMode == .context
            options.repeatingTrack = ps.repeatMode == .track
            playerStateProto.options = options

            device.playerState = playerStateProto
            device.transferData = Self.handover(of: ps, atMs: Int64(Date().timeIntervalSince1970 * 1000))?.serialized
        }

        return device
    }

    /// What another device takes over from here, written as the `transfer_data` the backend
    /// hands it, where the backend's own reading of the player state loses the session's row:
    /// while that row is an autoplay row, which the context's rows do not hold. Nil otherwise,
    /// and the backend builds the handover from the player state, as for every handover seen
    /// working.
    ///
    /// The web player and a phone write their own (2026-10-02); librespot and go-librespot do
    /// not. Built from this player state during autoplay, it held the context with its own rows
    /// only and the session at the context's last row, so a phone made the autoplay track a
    /// queued one, with the context's last track again after it. Written here as a phone and
    /// the web player write it: the station as the context, the context it went on from as
    /// `main_context`. The station's rows go as the context's page, from the session's row on: a
    /// phone handed none made a station of three tracks of its own, where the web player resolved
    /// one (2026-10-02).
    ///
    /// The position is the one at `now`, the moment of the report. The player state's is the
    /// one when the track started or last changed, and a phone took a handover's 0 at the start
    /// of a track as it was, 98 s later: as librespot does, it carries a position forward from
    /// its timestamp only when it is above zero.
    nonisolated static func handover(of ps: SpircPlayerState, atMs now: Int64) -> TransferState? {
        guard ps.sessionRow?.provider == "autoplay", let station = ps.autoplayContextUri, let uri = ps.trackUri else {
            return nil
        }
        let playsQueued = ps.trackProvider == "queue"

        var state = TransferState()
        state.contextUri = station
        state.mainContextUri = ps.contextUri.isEmpty ? nil : ps.contextUri
        state.mainContextMetadata = ps.contextMetadata
        state.currentTrackUri = uri
        state.currentTrackUid = ps.trackUid
        state.currentTrackMetadata = provided(uri: uri, uid: ps.trackUid, provider: ps.trackProvider, station: station).metadata
        state.playsQueuedTrack = playsQueued
        state.contextResumeUid = playsQueued ? ps.sessionRow?.uid : nil
        state.queuedTrackUris = ps.nextTracks.filter { $0.provider == "queue" }.map(\.uri)
        let current = playsQueued ? [] : [QueueItem(uri: uri, provider: ps.trackProvider, uid: ps.trackUid)]
        let stationRows = (current + ps.nextTracks).filter { $0.provider == "autoplay" && !$0.hidden }
        state.contextTrackUris = stationRows.map(\.uri)
        state.contextTrackUids = stationRows.map(\.uid)
        state.positionAsOfTimestamp = Int64(ps.positionMs)
        state.timestamp = Int64(ps.timestamp)
        state.isPaused = ps.isPaused
        state.positionAsOfTimestamp = state.position(atMs: now)
        state.timestamp = now
        state.shuffle = ps.shuffle
        state.repeatContext = ps.repeatMode == .context
        state.repeatTrack = ps.repeatMode == .track
        return state
    }

    /// A row as other devices are told it, as librespot's and a phone's read (2026-10-02). Proto3:
    /// a row without a uid sends "". Its metadata says where it came from: the context it belongs
    /// to as its `context_uri` and `entity_uri` (the album for a context row, the station for an
    /// autoplay row, which says `autoplay.is_autoplay` too), and `is_queued` for a queued row. A
    /// delimiter belongs to none, as a phone's carries none.
    nonisolated static func provided(uri: String, uid: String?, provider: String, context: String = "", station: String? = nil) -> ProvidedTrack {
        var track = ProvidedTrack(uri: uri, uid: uid ?? "", provider: provider)
        let belongsTo: String? = switch provider {
        case "context": context.isEmpty || uri == PlaybackQueue.delimiterUri ? nil : context
        case "autoplay": station
        default: nil
        }
        track.metadata["context_uri"] = belongsTo
        track.metadata["entity_uri"] = belongsTo
        if provider == "autoplay" {
            track.metadata["autoplay.is_autoplay"] = "true"
        }
        if provider == "queue" {
            track.metadata["is_queued"] = "true"
        }
        return track
    }

    /// A token that changes whenever what plays next does — librespot's
    /// `update_queue_revision`, a hash of the next tracks' uris.
    ///
    /// Clients cache the queue they show by it. Never sent, it stayed empty,
    /// and Spotify's web player kept showing the queue it first saw: after it
    /// started another album here, its queue panel still listed the old one.
    /// FNV-1a rather than `Hasher`, whose seed changes with every launch.
    nonisolated static func queueRevision(of uris: [String]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for uri in uris {
            for byte in uri.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
            }
            hash = (hash ^ 0xFF) &* 0x100_0000_01B3 // keeps ["ab", "c"] apart from ["a", "bc"]
        }
        return String(hash)
    }

    // MARK: - Dealer Subscriptions

    private nonisolated enum DealerPush: Sendable {
        case cluster(ClusterUpdateProto)
        case command(SpircRemoteCommand)
    }

    /// Hands the dealer's pushes to this actor one at a time, in the order
    /// they arrived. They used to hop through the main actor on the way, so
    /// a remote pause waited for whatever SwiftUI was busy with.
    private var dealerPushes: Task<Void, Never>?

    private func setupDealerSubscriptions() async {
        let (pushes, continuation) = AsyncStream.makeStream(of: DealerPush.self)

        dealerConnection.clusterUpdates
            .sink { continuation.yield(.cluster($0)) }
            .store(in: &subscriptions)

        dealerConnection.commands
            .sink { continuation.yield(.command($0)) }
            .store(in: &subscriptions)

        dealerPushes?.cancel()
        dealerPushes = Task { [weak self] in
            for await push in pushes {
                switch push {
                case let .cluster(update):
                    await self?.handleClusterUpdate(update)
                case let .command(command):
                    await self?.handleCommand(command)
                }
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
