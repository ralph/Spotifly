//
//  LibrespotClient.swift
//  SwiftLibrespot
//
//  The Spotify Connect controller the app talks to, as `LibrespotClient.shared`.
//
//  Everything user-facing reads the snapshots this client publishes; it owns
//  the machinery that produces them: one session (dealer, Spirc), which
//  registers a hidden device that does not play, and mirrors the cluster.
//  Spotify's Soloist plays for this Mac (`SoloistEngine`).
//

import Foundation
import Synchronization

/// Main client for Swift librespot.
///
/// An actor: every control call serializes here. The latest snapshot sits
/// behind a lock, readable synchronously without awaiting.
public actor LibrespotClient {
    // MARK: - Singleton

    public static let shared = LibrespotClient()

    // MARK: - Dependencies

    private let deviceInfo: DeviceInfo

    private var session: LibrespotSession?

    /// Consumes the current session's events; cancelled when it is torn down.
    private var sessionEvents: Task<Void, Never>?

    // MARK: - Connection Bookkeeping

    private var shuttingDown = false
    /// Bumped whenever an account-level event (logout, shutdown) invalidates
    /// work in flight. An initialization that awaited a network call while
    /// such an event landed must abandon rather than write its results.
    private var lifecycleGeneration = 0
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Snapshots (what the app shows)

    /// The latest snapshot, which the synchronous reads use.
    private nonisolated let latest = Mutex(PlayerSnapshot())

    /// Every change, for the one consumer that shows them. One that falls
    /// behind gets the newest snapshot, not the ones in between, and yielding
    /// never waits for it.
    nonisolated let snapshots: AsyncStream<PlayerSnapshot>
    private nonisolated let snapshotSink: AsyncStream<PlayerSnapshot>.Continuation

    /// Changes the latest snapshot and yields it. Only called on this actor,
    /// so snapshots go out in the order they were made.
    private func publish(_ change: (inout PlayerSnapshot) -> Void) {
        snapshotSink.yield(latest.withLock { snapshot in
            change(&snapshot)
            return snapshot
        })
    }

    // MARK: - Initialization

    private init() {
        deviceInfo = DeviceInfo.create(name: "Spotifly")
        (snapshots, snapshotSink) = AsyncStream.makeStream(of: PlayerSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        debugLog("LibrespotClient", "Created for device \(deviceInfo.deviceName) (\(deviceInfo.deviceId))")
    }

    // MARK: - Lifecycle

    /// Builds the session: the dealer socket and the Spirc registration. Spotify's Soloist
    /// plays for this Mac, so the device registers hidden, as one that cannot play does
    /// (`SpircController.buildDevice`), and the session needs only the token
    /// (`LibrespotSession.connect`).
    func initialize(httpCredentials: SpotifyCredentials) async throws {
        shuttingDown = false
        let generation = lifecycleGeneration

        reconnectTask?.cancel()
        reconnectTask = nil

        await teardown()

        if lifecycleGeneration != generation {
            throw LibrespotError.invalidState("Initialization superseded")
        }

        let newSession = LibrespotSession(deviceInfo: deviceInfo)
        session = newSession
        subscribeToSession(newSession)

        try await newSession.connect(signing: httpCredentials)

        // A logout or shutdown landed while we were connecting; everything
        // below would sign a signed-out account back in. Abandon instead.
        guard lifecycleGeneration == generation else {
            await newSession.disconnect()
            session = nil
            throw LibrespotError.invalidState("Initialization superseded")
        }

        flags.withLock { $0.hasSession = true }

        publishConnectionState(connected: true)

        debugLog("LibrespotClient", "Initialization complete")
    }

    /// Leaves Spotify Connect and tears everything down. Blocks auto-reconnect until
    /// the next `initialize`.
    public func shutdown() async {
        debugLog("LibrespotClient", "Shutting down")
        shuttingDown = true
        lifecycleGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardown()
        publishConnectionState(connected: false)
    }

    /// Shuts down and clears the snapshot, so a later login does not inherit
    /// the previous account's devices, queue, or playback state. The playback
    /// goes in `shutdown()`'s teardown.
    public func shutdownAndCleanup() async {
        await shutdown()
        publish {
            $0.devices = nil
            $0.queue = nil
            $0.activeDeviceId = ""
            $0.clusterRevision += 1
        }
    }

    /// Drops all connections and subscriptions, and the playback the session mirrored.
    /// Kept, it read as still playing over a session that is gone, and the next session's
    /// identical mirror was no change for the player model to pass on, so a rebuild went on
    /// showing a track nothing reported any more. Credentials survive. Sleep does not come
    /// through here: `disconnect()` keeps the track for the wake.
    private func teardown() async {
        sessionEvents?.cancel()
        sessionEvents = nil
        publish { $0.playback = nil }
        await session?.disconnect()
        session = nil

        flags.withLock {
            $0.hasSession = false
            $0.recovering = false
        }
    }

    // MARK: - Sleep / Wake / Recovery

    /// Disconnects without forgetting anything; `forceReconnect` revives it.
    public func disconnect() {
        debugLog("LibrespotClient", "Disconnect requested")
        Task { await session?.disconnect() }
    }

    /// Outcome of a reconnect request.
    ///
    /// `alreadyRecovering` and `noSession` both mean "nothing was started", but they need
    /// opposite responses: the first is fine to ignore because recovery is already under
    /// way, while the second means there is nothing to reconnect *to* and only a full
    /// rebuild will help. Collapsing them into one `false` is how a wake could end up
    /// doing nothing at all.
    enum ForceReconnectOutcome {
        case started
        case alreadyRecovering
        case noSession
    }

    /// Reconnects the session it has, for an account still signed in: a logout forgets the
    /// session's credentials (`clearStreamingCredentials`), so a signed-out account is never
    /// reconnected.
    private func runRecovery() async {
        defer { flags.withLock { $0.recovering = false } }
        guard !shuttingDown, let session, let credentials = await session.currentCredentials else { return }

        do {
            try await session.connect(signing: credentials)
            publishConnectionState(connected: true)
            debugLog("LibrespotClient", "Recovery succeeded")
        } catch {
            debugLog("LibrespotClient", "Recovery failed: \(error)")
            publishConnectionState(connected: false, error: error.localizedDescription)
        }
    }

    // MARK: - Credential Management

    /// Forgets the account's credentials, the session's, which a recovery reconnects with, so
    /// nothing can sign back in.
    public func clearStreamingCredentials() async {
        lifecycleGeneration += 1
        await session?.forgetCredentials()
    }

    // MARK: - Synchronous State (read without awaiting)

    /// Connection bookkeeping `forceReconnectSync` reads. The actor updates
    /// it; one lock around check-and-set keeps reconnects from doubling up.
    private nonisolated struct Flags {
        var hasSession = false
        var recovering = false

        /// Claims the recovery, unless there is no session to recover or
        /// someone is already at it.
        mutating func beginRecovery() -> ForceReconnectOutcome {
            guard hasSession else { return .noSession }
            guard !recovering else { return .alreadyRecovering }
            recovering = true
            return .started
        }
    }

    private nonisolated let flags = Mutex(Flags())

    nonisolated var currentConnectionState: LibrespotConnectionState? {
        latest.withLock { $0.connection }
    }

    /// Starts rebuilding the session if it is down, without blocking: the
    /// outcome says whether recovery began, was already under way, or is
    /// pointless, and the work itself continues in a task.
    ///
    /// Preferred over `PlaybackViewModel.forceReinitialize` wherever a session may exist:
    /// reinitializing tears the session down first, which invalidates any recovery already
    /// working the problem.
    nonisolated func forceReconnectSync() -> ForceReconnectOutcome {
        let outcome = flags.withLock { $0.beginRecovery() }
        if outcome == .started {
            Task { await self.runRecovery() }
        }
        return outcome
    }

    // MARK: - Session Wiring

    private func subscribeToSession(_ session: LibrespotSession) {
        sessionEvents?.cancel()
        let events = session.events
        sessionEvents = Task { await self.handle(events) }
    }

    /// Handles the session's events one at a time, in the order it sent them.
    private func handle(_ events: AsyncStream<LibrespotSession.Event>) async {
        for await event in events {
            switch event {
            case let .state(state):
                handleSessionState(state)
            case let .cluster(cluster):
                handleClusterUpdate(cluster)
            }
        }
    }

    private func handleSessionState(_ state: SessionState) {
        switch state {
        case .connected:
            publishConnectionState(connected: true)
        case .failed:
            publishConnectionState(connected: false)
            startAutoRecoveryIfNeeded()
        case .disconnected:
            // A disconnect somebody asked for waits for them to reconnect. The
            // one before sleep used to arm recovery a second later, so the app
            // reconnected as the Mac went to sleep and in every dark wake after.
            // A dying socket reports `.failed` first, which is what recovers.
            publishConnectionState(connected: false)
        case .connecting:
            break
        }
    }

    private func startAutoRecoveryIfNeeded() {
        guard !shuttingDown, flags.withLock({ $0.beginRecovery() }) == .started else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                self?.flags.withLock { $0.recovering = false }
                return
            }
            await self?.runRecovery()
        }
    }

    // MARK: - Cluster Handling

    private func handleClusterUpdate(_ cluster: SpircController.ClusterState) {
        let devices = cluster.devices.map(\.asEntity)

        // An empty active id is Connect saying "nobody is playing", which is a
        // state worth adopting rather than skipping: ignoring it left the app
        // pointing at a device that has since stopped, and routing commands to
        // it. Every device then shows as inactive, which is the intended reading.
        let activeId = cluster.activeDeviceId ?? ""
        publish {
            $0.devices = devices
            $0.activeDeviceId = activeId
            $0.clusterRevision += 1
        }

        if let remote = cluster.playerState {
            debugLog("LibrespotClient", "Mirroring \(remote.track?.uri ?? "no track") (playing=\(remote.isPlaying), paused=\(remote.isPaused)) from \(activeId.isEmpty ? "no active device" : activeId)")
            mirror(remote, deviceActive: !activeId.isEmpty)
        }
    }

    /// Shows what the active device is playing, Soloist included, so the
    /// now-playing bar and the queue follow playback wherever it is — and the
    /// transport controls, which route to the active device, act on what is
    /// on screen.
    ///
    /// With no device active, nothing plays, whatever the player state says.
    /// Spotify keeps a device's last report after the device has gone,
    /// "playing" included, and a launch after quitting mid-track showed that
    /// as playback running on no device at all.
    private func mirror(_ remote: PlayerState, deviceActive: Bool) {
        guard let track = remote.track, !track.uri.isEmpty else { return }

        let playing = deviceActive && remote.isPlaying && !remote.isPaused
        let options = remote.options
        let playback = PlaybackState(
            isPlaying: playing,
            trackUri: track.uri,
            positionMs: remote.positionAsOfTimestamp,
            durationMs: remote.duration,
            shuffle: options.shufflingContext,
            repeatTrack: options.repeatingTrack,
            repeatContext: options.repeatingContext,
            timestampMs: remote.timestamp,
            // Measured 2026-10-01: on an album's last track with repeat off the web player lists
            // only hidden rows, and names no reason not to skip next. A librespot made to name
            // one greyed Next here (2026-10-02).
            canSkipNext: !remote.disallowsSkippingNext,
            // The web player playing a station names it, and greys its own Shuffle, and
            // librespot does while it plays autoplay (2026-10-02).
            canShuffle: remote.restrictions.allowsShuffle,
            canRepeat: remote.restrictions.allows(.context),
        )
        let queue = Self.mirroredQueue(of: remote)
        publish {
            $0.playback = playback
            $0.queue = queue
        }
    }

    /// A row's uid, or none for one sent without; proto3 sends that as "".
    private nonisolated static func rowUid(_ track: ProvidedTrack) -> String? {
        track.uid.isEmpty ? nil : track.uid
    }

    /// The rows ahead up to the first `spotify:delimiter`, after which a device under repeat
    /// lists its context again.
    private nonisolated static func thisRound(of rows: [ProvidedTrack]) -> ArraySlice<ProvidedTrack> {
        rows.prefix { $0.uri != ProvidedTrack.delimiterUri }
    }

    /// Whether the sending device shows a row in its own queue; see `mirroredQueue(of:)`. Its
    /// delimiters are hidden too.
    private nonisolated static func isShown(_ track: ProvidedTrack) -> Bool {
        !track.isHidden
    }

    /// The queue another device reports, as the Queue section shows it.
    ///
    /// The context goes with it: the queue's heading and a double-click on one of its rows
    /// play from it.
    ///
    /// Rows the sender marks hidden are left out, as its own queue leaves them out. After a
    /// context's last track the web player sends a `spotify:delimiter` row, then the context
    /// again as its next iteration, for repeat to play: with repeat off every row from the
    /// delimiter on is `hidden`, with repeat on only the delimiters are. So the context's rows
    /// after the first delimiter are left out, hidden or not: one round. Rows after it that are
    /// not the context stay: librespot lists its autoplay rows there, shown, where a phone lists
    /// them straight after the context's last row (measured 2026-10-02).
    nonisolated static func mirroredQueue(of remote: PlayerState) -> QueueState {
        let item: (ProvidedTrack) -> QueueItem = { QueueItem(uri: $0.uri, provider: $0.provider, uid: rowUid($0)) }
        let round = thisRound(of: remote.nextTracks)
        let beyond = remote.nextTracks.dropFirst(round.count).filter { $0.provider != "context" && $0.uri != ProvidedTrack.delimiterUri }
        let ahead = round + beyond
        return QueueState(
            contextUri: remote.contextUri,
            currentTrack: remote.track.map(item),
            nextTracks: ahead.filter(isShown).map(item),
            // In play order, as the cluster keeps them.
            previousTracks: remote.prevTracks.filter(isShown).map(item),
            contextName: remote.contextMetadata.contextName,
        )
    }

    // MARK: - State Publishing

    private func publishConnectionState(
        connected: Bool,
        error: String? = nil,
    ) {
        let state = LibrespotConnectionState(
            sessionConnected: connected,
            deviceId: deviceInfo.deviceId,
            deviceName: deviceInfo.deviceName,
            lastError: error,
            connectedSinceMs: connected ? UInt64(Date().timeIntervalSince1970 * 1000) : nil,
        )
        publish { $0.connection = state }
    }
}

// MARK: - Device Mapping

extension SpircController.ClusterState.ConnectedDevice {
    /// The entity the rest of the app speaks.
    nonisolated var asEntity: Device {
        Device(
            id: id,
            name: name,
            type: deviceType.apiName,
            isActive: isActive,
            isPrivateSession: false,
            isRestricted: false,
            // Zero is a volume, not a missing one. Reporting nil for it made a
            // muted device indistinguishable from one that never said.
            volumePercent: Int((Double(volume) / 65535.0 * 100).rounded()),
            disableVolume: disableVolume,
        )
    }
}

extension SpotifyDeviceType {
    /// The lowercased type names `/me/player/devices` style payloads use.
    nonisolated var apiName: String {
        switch self {
        case .computer: "computer"
        case .tablet: "tablet"
        case .smartphone: "smartphone"
        case .speaker: "speaker"
        case .tv: "tv"
        case .avr: "avr"
        case .stb: "stb"
        case .audiodongle: "audiodongle"
        case .gameconsole: "gameconsole"
        case .castvideo: "castvideo"
        case .castaudio: "castaudio"
        case .automobile: "automobile"
        case .smartwatch: "smartwatch"
        case .chromebook: "chromebook"
        default: "unknown"
        }
    }
}
