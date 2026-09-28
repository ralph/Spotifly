//
//  LibrespotClient.swift
//  SwiftLibrespot
//
//  The playback engine behind the app's SpotifyPlayer facade.
//
//  Everything user-facing reads the snapshots this client publishes; it owns
//  the machinery that produces them: one session (AP socket, dealer, Spirc),
//  one audio pipeline, and the client-side queue that orders tracks.
//

import AVFoundation
import Foundation
import Synchronization

/// Main client for Swift librespot.
///
/// An actor: every control call serializes here. The latest snapshot sits
/// behind a lock, readable synchronously by the facade without awaiting.
public actor LibrespotClient {
    // MARK: - Singleton

    public static let shared = LibrespotClient()

    // MARK: - Dependencies

    private let deviceInfo: DeviceInfo
    private let storedCredentials = StoredCredentialsStore()

    private var session: LibrespotSession?
    private var spclient: SPClient?
    private var audioPipeline: AudioPipeline?

    /// Produces valid bearer tokens for HTTP endpoints (dealer, spclient,
    /// Web API fallbacks). Injected by the facade, which binds it to the
    /// app's keymaster grant.
    private var tokenProvider: (@Sendable () async throws -> String)?
    private var clientTokenProvider: (@Sendable () async throws -> String)?

    /// The account the session plays as.
    private var usernameProvider: (@Sendable () async -> String?)?

    /// Consumes the current session's events; cancelled when it is torn down.
    private var sessionEvents: Task<Void, Never>?

    // MARK: - Queue & Playback Bookkeeping

    private var playbackQueue = PlaybackQueue()

    /// Logical Connect volume (0…65535), mirrored into player state.
    private var logicalVolume: UInt32 = 32767

    private var shuffleEnabled = false
    private var repeatMode = PlaybackQueue.RepeatMode.off

    // MARK: - Connection Bookkeeping

    private var shuttingDown = false
    /// Bumped whenever an account-level event (logout, shutdown) invalidates
    /// work in flight. An initialization that awaited a network call while
    /// such an event landed must abandon rather than write its results.
    private var lifecycleGeneration = 0
    private var reconnectTask: Task<Void, Never>?
    /// Consumes the current audio pipeline's events; cancelled whenever a new
    /// pipeline replaces the old one.
    private var pipelineEvents: Task<Void, Never>?

    /// What the local player is doing, or nil when it holds nothing.
    ///
    /// Kept apart from the snapshot's playback, which shows *whichever* device
    /// is playing: while another one is, it mirrors the cluster.
    /// Only this is ever reported to the cluster as this device's state —
    /// reporting the mirror would claim another device's playback as ours,
    /// and with it the active role.
    private var localState: PlaybackState?

    // MARK: - Snapshots (what the app shows)

    /// The latest snapshot, which the facade's synchronous reads use.
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

    /// Builds a full session: accesspoint login, dealer socket, Spirc
    /// registration, and the audio pipeline.
    ///
    /// Credentials are resolved inside: a previously captured reusable login
    /// comes first, falling back to a fresh token from the provider. A
    /// successful token login stores its reusable credentials for next time.
    public func initialize(
        tokenProvider provider: @escaping @Sendable () async throws -> String,
        clientTokenProvider: (@Sendable () async throws -> String)? = nil,
        usernameProvider: @escaping @Sendable () async -> String?,
    ) async throws {
        tokenProvider = provider
        self.clientTokenProvider = clientTokenProvider
        self.usernameProvider = usernameProvider
        shuttingDown = false
        let generation = lifecycleGeneration

        reconnectTask?.cancel()
        reconnectTask = nil

        await teardown()

        let credentials = try await credentialsForLogin()

        if lifecycleGeneration != generation {
            throw LibrespotError.invalidState("Initialization superseded")
        }

        let newSession = LibrespotSession(deviceInfo: deviceInfo)
        session = newSession
        subscribeToSession(newSession)

        let welcome = try await newSession.connect(credentials: credentials) {
            try await provider()
        } clientTokenProvider: { [clientTokenProvider] in
            guard let clientTokenProvider else { throw LibrespotError.notInitialized }
            return try await clientTokenProvider()
        }

        // A logout or shutdown landed while we were connecting; everything
        // below would sign a signed-out account back in. Abandon instead.
        guard lifecycleGeneration == generation else {
            await newSession.disconnect()
            session = nil
            throw LibrespotError.invalidState("Initialization superseded")
        }

        // First successful login (or a refresh of it): capture the reusable
        // blob so future launches skip the browser entirely.
        if credentials.accessToken != nil {
            storedCredentials.save(StoredLogin(
                username: welcome.canonicalUsername,
                authData: welcome.reusableAuthCredentials,
                authType: welcome.reusableAuthCredentialsType.rawValue,
            ))
        }

        await attachTransport()

        flags.withLock {
            $0.hasEverConnected = true
            $0.hasSession = true
        }

        publishConnectionState(connected: true)

        debugLog("LibrespotClient", "Initialization complete")

        #if DEBUG
            // SPOTIFLY_DEBUG_DROP_AP_AFTER=<seconds>: drop the accesspoint socket
            // that long after login. Spotify resets it now and then, and nothing
            // on its side can be asked to, so this is how a recovery is tested.
            if let after = ProcessInfo.processInfo.environment["SPOTIFLY_DEBUG_DROP_AP_AFTER"],
               let seconds = Double(after)
            {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    await session?.accesspoint?.debugDropConnection()
                }
            }
        #endif
    }

    /// Chooses what to log in with: the stored reusable login if present,
    /// otherwise a fresh token plus username.
    private func credentialsForLogin() async throws -> APCredentials {
        if let stored = storedCredentials.load() {
            return .stored(username: stored.username, authData: stored.authData)
        }

        guard let tokenProvider else {
            throw LibrespotError.notInitialized
        }
        let token = try await tokenProvider()
        guard let username = await usernameProvider?(), !username.isEmpty else {
            throw LibrespotError.authenticationFailed("No account name available for streaming login")
        }
        return .accessToken(token, username: username)
    }

    /// Says goodbye and tears everything down. Blocks auto-reconnect until
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
    /// the previous account's devices, queue, or playback state.
    public func shutdownAndCleanup() async {
        await shutdown()
        publish {
            $0.devices = nil
            $0.queue = nil
            $0.activeDeviceId = ""
            $0.clusterRevision += 1
        }
    }

    /// Drops all connections and subscriptions, and the playback that ran on
    /// them. Kept, it read as still playing over a pipeline that is gone, and
    /// the next session's identical mirror was no change for the player model
    /// to pass on. Credentials survive. Sleep does not come through here:
    /// `disconnect()` keeps its track for the wake.
    private func teardown() async {
        sessionEvents?.cancel()
        sessionEvents = nil
        await audioPipeline?.stop()
        clearLocalState()
        await session?.disconnect()
        audioPipeline = nil
        session = nil
        spclient = nil

        flags.withLock {
            $0.hasSession = false
            $0.recovering = false
        }
    }

    // MARK: - Sleep / Wake / Recovery

    /// Disconnects without forgetting anything; `forceReconnect` revives it.
    public func disconnect() {
        debugLog("LibrespotClient", "Disconnect requested")

        // Playback goes down with the socket: buffered PCM must not outlive
        // the device going to sleep, and a running decode loop cannot fetch
        // audio keys from a dead accesspoint anyway.
        Task {
            // What was playing is kept as paused where it stopped, which is
            // where the wake's reconnect loads it. The stop alone left it
            // "playing" at position zero, and the wake played it from the top.
            if let current = localState, current.isPlaying {
                let position = await audioPipeline?.currentPositionMs() ?? positionCache.withLock { $0 }
                publishPlaybackState(for: current.trackUri, playing: false, paused: true, positionMs: Int64(position))
            }
            await audioPipeline?.stop()
            await session?.disconnect()
        }
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

    private func runRecovery() async {
        defer { flags.withLock { $0.recovering = false } }
        guard !shuttingDown else { return }
        guard let session, let credentials = await session.currentCredentials, let tokenProvider else { return }

        // What to come back to, read before reconnecting: the new session's
        // first cluster can arrive while it is still being set up.
        let was = localState

        do {
            _ = try await session.connect(credentials: credentials) { [tokenProvider] in
                try await tokenProvider()
            } clientTokenProvider: { [clientTokenProvider] in
                guard let clientTokenProvider else { throw LibrespotError.notInitialized }
                return try await clientTokenProvider()
            }

            await attachTransport()

            // A reset leaves the track playing from memory, or loading, as a
            // Next pressed meanwhile does, which waits for the new socket. The
            // rebuilt session only has to be told: it registered with no active
            // device. Sleep stopped the pipeline, so reload where we were, paused
            // if it was; before sleep, `disconnect()` kept that place in
            // `localState`.
            if let audioPipeline, await !audioPipeline.isStopped {
                debugLog("LibrespotClient", "Recovery kept the pipeline's track")
                await publishPlaybackStateRefresh()
            } else if let was, let uri = playbackQueue.currentUri {
                let resumeAt = UInt64(max(0, was.positionMs))
                debugLog("LibrespotClient", "Recovery reloading \(uri) at \(resumeAt)ms\(was.isPlaying ? "" : ", paused")")
                try? await audioPipeline?.playTrack(uri: uri, positionMs: resumeAt, paused: !was.isPlaying)
            }

            publishConnectionState(connected: true)
            debugLog("LibrespotClient", "Recovery succeeded")
        } catch {
            debugLog("LibrespotClient", "Recovery failed: \(error)")
            publishConnectionState(connected: false, error: error.localizedDescription)
        }
    }

    /// Creates SPClient and the audio pipeline for a new session. A reconnect
    /// keeps both: neither holds the socket, and the pipeline asks the session
    /// for it each time it needs an audio key.
    private func attachTransport() async {
        guard let tokenProvider, let session else { return }

        if spclient == nil {
            spclient = await SPClient(
                tokenProvider: { [tokenProvider] in try await tokenProvider() },
                clientTokenProvider: { [clientTokenProvider] in
                    guard let clientTokenProvider else { throw LibrespotError.notInitialized }
                    return try await clientTokenProvider()
                },
                spclientHost: session.spclientHost,
                deviceId: deviceInfo.deviceId,
            )
        }

        guard let accesspoint = await session.accesspoint else { return }

        await spclient?.setCountryCode(accesspoint.lastCountryCode)

        guard audioPipeline == nil else { return }

        let pipeline = AudioPipeline(
            audioKeyProvider: AudioKeyProvider { [weak session] in await session?.connectedAccesspoint },
            spclient: spclient,
            sink: SpotifyPlayer.audioRenderer,
        )
        audioPipeline = pipeline
        subscribeToPipeline(pipeline)
        await applyPlaybackSettings()

        // A new pipeline hears of the next track only at the next track
        // change, so the first boundary after a rebuild was not gapless.
        announceNextTrack()
    }

    // MARK: - Credential Management

    /// Removes the stored reusable login so nothing can sign back in.
    public func clearStreamingCredentials() async {
        storedCredentials.clear()
        lifecycleGeneration += 1
        await session?.forgetCredentials()
    }

    // MARK: - Playback: Starting Content

    /// Plays a track, album, playlist, artist, or station URI/URL.
    /// - Parameters:
    ///   - trackIndex: index within the context to start at (-1 = first).
    ///   - startingAtUri: track to start on when the caller knows the uri but
    ///     not its index — a Connect `play` names both a context and a
    ///     `skip_to.track_uri`, and only the resolved list can turn one into
    ///     the other.
    ///   - positionMs: where in that track to start.
    ///   - paused: load it without starting playout, as a paused handover does.
    public func play(
        uriOrUrl: String,
        trackIndex: Int,
        startingAtUri: String? = nil,
        positionMs: UInt64 = 0,
        paused: Bool = false,
    ) async throws {
        let uri = Self.normalizedUri(uriOrUrl)

        if uri.contains("spotify:track:") {
            setQueue(contextUri: uri, tracks: [uri], startIndex: 0)
            try await loadCurrentTrack(positionMs: positionMs, paused: paused)
            return
        }

        // Anything else is a context that needs resolving to a track list.
        guard let spclient else {
            throw LibrespotError.notInitialized
        }

        debugLog("LibrespotClient", "Resolving context \(uri)")
        let context = try await spclient.resolveContext(uri)
        guard !context.tracks.isEmpty else {
            throw LibrespotError.trackNotFound("Context has no tracks")
        }

        var tracks = context.tracks
        let start: Int
        if trackIndex >= 0 {
            start = min(trackIndex, tracks.count - 1)
        } else if let startingAtUri {
            // A track the resolved list does not name — a relinked id, a
            // window that moved — still has to be the one that plays, so it
            // goes in front of the context rather than starting it over.
            if let found = tracks.firstIndex(of: startingAtUri) {
                start = found
            } else {
                tracks.insert(startingAtUri, at: 0)
                start = 0
            }
        } else {
            start = 0
        }
        setQueue(contextUri: context.uri.isEmpty ? uri : context.uri, tracks: tracks, startIndex: start)
        try await loadCurrentTrack(positionMs: positionMs, paused: paused)
    }

    public func playTracks(_ uris: [String], positionMs: UInt64 = 0) async throws {
        let normalized = uris.map(Self.normalizedUri)
        guard let first = normalized.first else {
            throw LibrespotError.invalidState("No tracks to play")
        }

        if normalized.count == 1, first.contains("spotify:track:") {
            try await play(uriOrUrl: first, trackIndex: 0, positionMs: positionMs)
            return
        }

        setQueue(contextUri: "", tracks: normalized, startIndex: 0)
        try await loadCurrentTrack(positionMs: positionMs)
    }

    /// Song radio for a seed track, resolved through its station context.
    public func playRadio(trackUri: String) async throws {
        guard let id = SpotifyAPI.parseTrackURI(trackUri) ?? Self.trackIdOnly(from: trackUri) else {
            throw LibrespotError.trackNotFound("Not a track uri")
        }
        try await play(uriOrUrl: "spotify:station:track:\(id)", trackIndex: 0)
    }

    // MARK: - Playback: Transport

    public func pause() async {
        await audioPipeline?.pause()
    }

    public func resume() async {
        await audioPipeline?.resume()
    }

    public func stop() async {
        await audioPipeline?.stop()
    }

    public func seek(positionMs: UInt32) async throws {
        try await audioPipeline?.seek(positionMs: UInt64(positionMs))
    }

    public func next() async throws {
        try await advanceUserInitiated()
    }

    public func previous() async throws {
        defer { publishQueue() }

        if let previous = playbackQueue.backward() {
            try await loadAndPlay(previous)
        } else {
            // Nowhere back: restart the current track, like every other client.
            try await audioPipeline?.seek(positionMs: 0)
        }
    }

    /// Queues a track, or every track of an album or playlist in order.
    public func addToQueue(uri: String) async {
        let tracks: [String]
        do {
            tracks = try await queueableTracks(for: uri)
        } catch {
            debugLog("LibrespotClient", "Could not queue \(uri): \(error.localizedDescription)")
            return
        }
        for track in tracks {
            playbackQueue.enqueue(track)
        }
        publishQueue()
        // The queue is part of the reported player state, and heartbeats only
        // repeat the last report: without this, other devices did not see the
        // track, and a transfer before the next state change dropped it.
        if localState != nil {
            reportPlaybackToCluster()
        }
    }

    /// The tracks queueing `uri` means: the track itself, or the tracks of the
    /// album or playlist it names.
    ///
    /// "Play next" on an album or a playlist hands over the context's uri. It
    /// used to be enqueued as it was, so the pipeline was later asked to load
    /// an album as a track, failed, and auto-advance stopped playback there.
    func queueableTracks(for uri: String) async throws -> [String] {
        let normalized = Self.normalizedUri(uri)
        if normalized.hasPrefix("spotify:track:") {
            return [normalized]
        }
        guard let spclient else {
            throw LibrespotError.notInitialized
        }
        return try await spclient.resolveContext(normalized).tracks
    }

    public func setShuffle(_ enabled: Bool) async {
        shuffleEnabled = enabled
        playbackQueue.setShuffle(enabled)
        // Shuffle reorders what comes next, so the queue views move with it.
        publishQueue()
        await publishPlaybackStateRefresh()
    }

    /// Repeat leaves the queue's order alone — only the flags move, so this
    /// refreshes the playback state and nothing else.
    func setRepeat(_ mode: PlaybackQueue.RepeatMode) async {
        repeatMode = mode
        playbackQueue.setRepeat(mode)
        announceNextTrack()
        await publishPlaybackStateRefresh()
    }

    /// Tells the pipeline what auto-advance will play, so it can fetch it
    /// before the current track ends. Under repeat-one that is the same track,
    /// which the pipeline already holds.
    private func announceNextTrack() {
        let next = repeatMode == .track ? playbackQueue.currentUri : playbackQueue.upcoming(limit: 1).first?.uri
        Task { [audioPipeline] in await audioPipeline?.setNextTrack(next) }
    }

    // MARK: - Volume

    /// Sets the **logical** Connect volume (0…1) — the number reported to the
    /// cluster and mirrored into player state.
    ///
    /// Deliberately does not touch the audio gain. That is
    /// `SpotifyPlayer.setOutputVolume`, which runs the value through
    /// librespot's logarithmic taper first; applying the raw linear value here
    /// as well overwrote it, turning an intended 0.032 at half-slider into 0.5
    /// — about 24 dB louder than asked for, on every track start.
    ///
    /// Both directions still reach the gain: a local change applies it in
    /// `PlaybackViewModel.volume.didSet` before it ever gets here, and a remote
    /// one comes back out through the snapshot's volume into that same setter.
    public func setVolume(_ volume: Double) async {
        let clamped = max(0, min(1, volume))
        logicalVolume = UInt32(clamped * 65535)
        publish { $0.volume = clamped }
        // Other clients draw this device's slider from what Spirc reports.
        await session?.reportLocalVolume(logicalVolume)
    }

    // MARK: - Synchronous State (read by the facade without awaiting)

    /// Connection bookkeeping the synchronous facade reads. The actor updates
    /// it; one lock around check-and-set keeps reconnects from doubling up.
    private nonisolated struct Flags {
        var hasEverConnected = false
        var hasSession = false
        var recovering = false

        /// Claims the recovery, unless there is no session to recover or
        /// someone is already at it.
        mutating func beginRecovery() -> ForceReconnectOutcome {
            guard hasEverConnected, hasSession else { return .noSession }
            guard !recovering else { return .alreadyRecovering }
            recovering = true
            return .started
        }
    }

    private nonisolated let flags = Mutex(Flags())

    nonisolated var currentConnectionState: LibrespotConnectionState? {
        latest.withLock { $0.connection }
    }

    nonisolated var isPlayingFlagValue: Bool {
        latest.withLock { $0.playback?.isPlaying == true }
    }

    nonisolated var positionMsCached: UInt64 {
        positionCache.withLock { $0 }
    }

    /// Whether this device is the cluster's active one.
    nonisolated var isActiveDeviceFlagValue: Bool {
        latest.withLock { $0.activeDeviceId == deviceInfo.deviceId }
    }

    /// Position cache, fed by the pipeline's position ticks and read from
    /// anywhere.
    private nonisolated let positionCache = Mutex<UInt64>(0)

    /// Starts rebuilding the session if it is down, without blocking: the
    /// outcome says whether recovery began, was already under way, or is
    /// pointless, and the work itself continues in a task.
    nonisolated func forceReconnectSync() -> ForceReconnectOutcome {
        let outcome = flags.withLock { $0.beginRecovery() }
        if outcome == .started {
            Task { await self.runRecovery() }
        }
        return outcome
    }

    // MARK: - Settings

    /// Applies the persisted playback settings — bitrate and gapless — to the
    /// pipeline. Called when either changes and again for every pipeline a
    /// new session builds, so a rebuilt session does not silently fall back
    /// to the defaults.
    ///
    /// The bitrate lives in `SpotifyPlayer.Bitrate`, which owns both the
    /// stored value and the names the user sees; this is the only place it is
    /// turned into a quality the pipeline can select files by.
    public func applyPlaybackSettings() async {
        let quality: AudioPipeline.Quality = switch SpotifyPlayer.bitrate {
        case .low: .low
        case .normal: .normal
        case .high: .high
        }
        await audioPipeline?.setQuality(quality)
        await audioPipeline?.setGapless(SpotifyPlayer.gapless)
    }

    // MARK: - Queue Plumbing

    private func setQueue(contextUri: String, tracks: [String], startIndex: Int) {
        playbackQueue.setContext(uri: contextUri, tracks: tracks, startIndex: startIndex)
        publishQueue()
    }

    private func loadCurrentTrack(positionMs: UInt64 = 0, paused: Bool = false) async throws {
        guard let uri = playbackQueue.currentUri ?? playbackQueue.advance() else {
            throw LibrespotError.invalidState("Nothing to play")
        }
        try await loadAndPlay(uri, positionMs: positionMs, paused: paused)
    }

    /// Starts audio for a uri that is already the queue's current track.
    ///
    /// Deliberately separate from `play`: advancing through an existing queue
    /// must not rebuild it.
    private func loadAndPlay(_ uri: String, positionMs: UInt64 = 0, paused: Bool = false) async throws {
        guard let audioPipeline else {
            throw LibrespotError.notInitialized
        }

        // The optimistic state below must not carry the previous track's
        // length; until metadata lands, zero is the honest answer.
        knownDurationMs = 0
        let position = UInt32(clamping: positionMs)
        publishPlaybackState(for: uri, playing: !paused, paused: paused, positionMs: Int64(position))

        do {
            try await audioPipeline.playTrack(uri: uri, positionMs: positionMs, paused: paused)
        } catch is CancellationError {
            // A newer load took over while this one waited, and has already
            // published its own state; clearing it here would erase that.
            throw CancellationError()
        } catch {
            // The optimistic state above claimed this track was playing. If
            // metadata, the key, the CDN or the decoder said otherwise, leaving
            // it there shows a running track over silence — and auto-advance,
            // which swallows the error, would sit on it forever.
            clearLocalState()
            throw error
        }

        knownDurationMs = await audioPipeline.currentDurationMs
    }

    /// Auto-advance at end of track.
    private func handleEndOfTrack(_ uri: String) {
        Task {
            if repeatMode == .track {
                try? await loadAndPlay(uri)
                return
            }
            if let upcoming = playbackQueue.advance() {
                try? await loadAndPlay(upcoming)
            } else {
                await rewindContext()
            }
            // The advance moved current/history/next; queue views need it.
            publishQueue()
        }
    }

    /// Manual skip: always moves somewhere, wrapping past the end when repeat
    /// allows and rewinding the context otherwise.
    private func advanceUserInitiated() async throws {
        defer { publishQueue() }

        // A manual skip moves even under repeat-one; only auto-advance honors it.
        if let upcoming = playbackQueue.advance(respectingRepeat: false) {
            try await loadAndPlay(upcoming)
        } else {
            await rewindContext()
        }
    }

    /// The queue has run out with nothing to repeat: back to the first track
    /// of the context, loaded and paused at its start, as librespot's
    /// `handle_stop` leaves it. Other devices show a stopped player on that
    /// track, and their play button plays it.
    ///
    /// This used to stop and report no player state at all, while the device
    /// stayed the active one. The web player read that as nothing new and
    /// went on showing this Mac playing the last second of the last track,
    /// its play button sending pause.
    private func rewindContext() async {
        let tracks = playbackQueue.contextTracks
        guard !tracks.isEmpty else {
            await audioPipeline?.stop()
            clearLocalState()
            return
        }
        debugLog("LibrespotClient", "End of the context; back to its first track, paused")
        playbackQueue.setContext(uri: playbackQueue.contextUri, tracks: tracks, startIndex: 0)
        try? await loadCurrentTrack(paused: true)
    }

    /// Publishes the queue, with the context it plays from.
    private func publishQueue() {
        announceNextTrack()
        let queue = QueueState(
            contextUri: playbackQueue.contextUri,
            currentTrack: playbackQueue.currentUri.map { QueueItem(uri: $0, provider: "context") },
            nextTracks: playbackQueue.upcoming().map { QueueItem(uri: $0.uri, provider: $0.provider) },
            previousTracks: playbackQueue.recent().map { QueueItem(uri: $0.uri, provider: $0.provider) },
        )
        publish { $0.queue = queue }
    }

    // MARK: - Pipeline Wiring

    private func subscribeToPipeline(_ pipeline: AudioPipeline) {
        pipelineEvents?.cancel()
        let events = pipeline.events
        pipelineEvents = Task { await self.handle(events) }
    }

    /// Handles the pipeline's events one at a time, in the order it sent
    /// them. Each used to reach this actor in a task of its own, so two sent
    /// back to back, a pause and a resume, could be handled the other way round.
    private func handle(_ events: AsyncStream<AudioPipeline.Event>) async {
        for await event in events {
            switch event {
            case let .state(state):
                await handlePipelineState(state)
            case let .position(positionMs):
                positionCache.withLock { $0 = positionMs }
            case let .endOfTrack(uri):
                handleEndOfTrack(uri)
            case let .error(error):
                debugLog("LibrespotClient", "Audio pipeline error: \(error.localizedDescription)")
                clearLocalState()
            }
        }
    }

    /// The local player holds nothing any more.
    private func clearLocalState() {
        localState = nil
        publish { $0.playback = nil }
    }

    private func handlePipelineState(_ state: AudioPipeline.AudioPlaybackState) async {
        switch state {
        case .idle, .loading:
            break // end-of-track and stop own the nil transition, and a load publishes its own

        case let .playing(trackUri):
            let position = await audioPipeline?.currentPositionMs() ?? 0
            publishPlaybackState(for: trackUri, playing: true, paused: false, positionMs: Int64(position))

        case let .paused(trackUri):
            let position = await audioPipeline?.currentPositionMs() ?? 0
            publishPlaybackState(for: trackUri, playing: false, paused: true, positionMs: Int64(position))
        }

        reportPlaybackToCluster()
    }

    /// Mirrors local playback into Spirc's connect state so other Spotify
    /// clients see this device playing, can command it, and can take it over.
    ///
    /// The context and the queue around the track go with it: a transfer away
    /// hands the receiving device exactly this, so without them it could only
    /// continue the one track and stop.
    ///
    /// Reports go out one at a time, each built from the state as it is when
    /// it goes. Every remote command is acknowledged with a report the moment
    /// it returns, which can be before the pipeline's own state event has
    /// updated `localState`. Taken as snapshots and sent side by side, that
    /// stale report and the fresh one raced, and Spotify kept whichever it
    /// took last: after a pause from the web player it showed this Mac
    /// playing, its play button sent pause, and the next launch mirrored the
    /// stale state back as playback.
    private func reportPlaybackToCluster() {
        reportDue = true
        guard reporting == nil else { return }
        reporting = Task {
            while reportDue {
                reportDue = false
                await sendPlaybackReport()
            }
            reporting = nil
        }
    }

    /// Whether another report is due once the one going out has been sent.
    private var reportDue = false
    /// Sends the reports in turn; nil while none is going out.
    private var reporting: Task<Void, Never>?

    private func sendPlaybackReport() async {
        guard let session else { return }
        guard let current = localState else {
            await session.reportLocalPlayerState(nil, active: false)
            return
        }

        let spircState = await SpircController.SpircPlayerState(
            isPlaying: current.isPlaying,
            isPaused: current.isPaused,
            trackUri: current.trackUri.isEmpty ? nil : current.trackUri,
            positionMs: UInt64(max(0, current.positionMs)),
            durationMs: UInt64(max(0, (audioPipeline?.currentDurationMs) ?? current.durationMs)),
            shuffle: current.shuffle,
            repeatMode: current.repeatTrack ? .track : (current.repeatContext ? .context : .off),
            // The moment the position was read, not now: a republish of an
            // older state would otherwise tell other devices the track jumped
            // back to where it was when that state was taken.
            timestamp: UInt64(max(0, current.timestampMs)),
            contextUri: playbackQueue.contextUri,
            contextIndex: playbackQueue.contextPosition,
            trackProvider: playbackQueue.currentProvider,
            nextTracks: playbackQueue.upcoming(),
            previousTracks: Array(playbackQueue.recent().reversed()),
        )
        await session.reportLocalPlayerState(spircState, active: current.isPlaying)
    }

    // MARK: - Session Wiring

    private func subscribeToSession(_ session: LibrespotSession) {
        sessionEvents?.cancel()
        let events = session.events
        sessionEvents = Task { await self.handle(events) }
    }

    /// Handles the session's events one at a time, in the order it sent them.
    ///
    /// A remote command is only started in order, in a task of its own, as
    /// each was before: a Next then supersedes a play that is still loading,
    /// through the pipeline's load generation, where handling commands one at
    /// a time would hold the skip up until the load had finished.
    private func handle(_ events: AsyncStream<LibrespotSession.Event>) async {
        for await event in events {
            switch event {
            case let .state(state):
                handleSessionState(state)
            case let .cluster(cluster):
                await handleClusterUpdate(cluster)
            case let .command(command):
                Task { await executeRemoteCommand(command) }
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
            // reconnected as the Mac went to sleep and in every dark wake after,
            // and started playing there into an output that could not start.
            // A dying socket reports `.failed` first, which is what recovers.
            publishConnectionState(connected: false)
        case .connecting, .authenticating:
            break
        case let .reconnecting(attempt):
            publishConnectionState(connected: false, reconnectAttempt: UInt32(attempt))
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

    private func handleClusterUpdate(_ cluster: SpircController.ClusterState) async {
        let devices = cluster.devices.map(\.asEntity)

        // An empty active id is Connect saying "nobody is playing", which is a
        // state worth adopting rather than skipping: ignoring it left the app
        // pointing at a device that has since stopped, and routing commands to
        // it. Every device then shows as inactive, which is the intended reading.
        let activeId = cluster.activeDeviceId ?? ""
        let wasActive = isActiveDeviceFlagValue
        let nowActive = !activeId.isEmpty && activeId == deviceInfo.deviceId
        publish {
            $0.devices = devices
            $0.activeDeviceId = activeId
            $0.clusterRevision += 1
        }

        if nowActive, !wasActive {
            debugLog("LibrespotClient", "This device is now the active one")
        } else if !nowActive, wasActive {
            debugLog("LibrespotClient", "No longer the active device (now: \(activeId.isEmpty ? "nobody" : activeId))")
            // Only a device that *took* playback is a reason to stop. An empty
            // id is nobody: our own goodbye leaves one when the session drops,
            // and the rebuilt session's registration is answered with it —
            // stopping then turned a network blip into silence. Spirc keeps
            // claiming the role, and the next report takes it back.
            if !activeId.isEmpty {
                await standDown()
            }
        }

        if !nowActive, localState == nil, let remote = cluster.playerState {
            debugLog("LibrespotClient", "Mirroring \(remote.track?.uri ?? "no track") (playing=\(remote.isPlaying), paused=\(remote.isPaused)) from \(activeId.isEmpty ? "no active device" : activeId)")
            mirror(remote, deviceActive: !activeId.isEmpty)
        }
    }

    /// Another device took playback: this one stops, as librespot's Spirc does
    /// when a cluster update names someone else (`handle_cluster_update`).
    ///
    /// Without the stop, handing playback to a phone left it playing in two
    /// places. Spirc also has to stop asserting `is_active`, or the next
    /// heartbeat pulls playback straight back here.
    private func standDown() async {
        debugLog("LibrespotClient", "Another device took playback; stopping here")
        await session?.reportLocalActive(false)
        clearLocalState()
        await audioPipeline?.stop()
    }

    /// Shows what the active device is playing while this one plays nothing,
    /// so the now-playing bar and the queue follow playback that was handed
    /// away — and the transport controls, which route to the active device,
    /// act on what is on screen.
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
            isPaused: !playing,
            trackUri: track.uri,
            positionMs: remote.positionAsOfTimestamp,
            durationMs: remote.duration,
            shuffle: options.shufflingContext,
            repeatTrack: options.repeatingTrack,
            repeatContext: options.repeatingContext,
            timestampMs: remote.timestamp,
        )
        // The context goes with the queue, as for local playback: the queue's
        // heading and a double-click on one of its rows play from it. Without
        // it they named the last local context.
        let queue = QueueState(
            contextUri: remote.contextUri,
            currentTrack: QueueItem(uri: track.uri, provider: track.provider),
            nextTracks: remote.nextTracks.map { QueueItem(uri: $0.uri, provider: $0.provider) },
            previousTracks: remote.prevTracks.reversed().map { QueueItem(uri: $0.uri, provider: $0.provider) },
        )
        publish {
            $0.playback = playback
            $0.queue = queue
        }
    }

    /// Picks up playback another device handed over — librespot's
    /// `handle_transfer`: the same context, the same track, the same place in
    /// it, the same options, and paused if it was paused.
    private func takeOver(_ transfer: TransferState) async {
        guard let track = transfer.currentTrackUri else {
            debugLog("LibrespotClient", "Transfer named no track; ignoring it")
            return
        }
        let positionMs = UInt64(transfer.position(atMs: Int64(Date().timeIntervalSince1970 * 1000)))
        debugLog(
            "LibrespotClient",
            "Taking over \(track) in \(transfer.contextUri) at \(positionMs)ms (reported \(transfer.positionAsOfTimestamp)ms at \(transfer.timestamp))\(transfer.isPaused ? ", paused" : "")",
        )

        // Active even when the handover arrives paused: the sender has already
        // let go, and a paused player is still the one that holds playback.
        await session?.reportLocalActive(true)

        shuffleEnabled = transfer.shuffle
        playbackQueue.setShuffle(transfer.shuffle)
        repeatMode = transfer.repeatTrack ? .track : (transfer.repeatContext ? .context : .off)
        playbackQueue.setRepeat(repeatMode)
        // Before loading, so the first report and the next-track fetch already
        // see the sender's queue.
        playbackQueue.replaceUserQueue(with: transfer.queuedTrackUris)

        do {
            if !transfer.contextUri.isEmpty {
                try await play(
                    uriOrUrl: transfer.contextUri,
                    trackIndex: -1,
                    startingAtUri: track,
                    positionMs: positionMs,
                    paused: transfer.isPaused,
                )
            } else {
                // Started from a bare list of uris, so the list is all there is.
                let tracks = transfer.contextTrackUris.contains(track) ? transfer.contextTrackUris : [track]
                setQueue(contextUri: "", tracks: tracks, startIndex: tracks.firstIndex(of: track) ?? 0)
                try await loadCurrentTrack(positionMs: positionMs, paused: transfer.isPaused)
            }
        } catch is CancellationError {
            // A newer load took over, and it reports for itself.
        } catch {
            // Let the role go again, or the cluster goes on showing this device
            // as the one playing — over silence, with every control sent here.
            debugLog("LibrespotClient", "Transfer failed to load: \(error.localizedDescription)")
            await session?.reportLocalActive(false)
            reportPlaybackToCluster()
        }
    }

    // MARK: - Remote Commands

    private func executeRemoteCommand(_ envelope: SpircRemoteCommand) async {
        let command = envelope.command

        debugLog("LibrespotClient", "Remote command: \(command)")

        switch command {
        case let .play(playCommand):
            // The context is the queue; a track named beside it only says where
            // to start in it. Preferring the track built a one-track queue and
            // threw the rest of the playlist away, so a remote "play this album
            // from track 4" stopped after track 4.
            let positionMs = playCommand.positionMs ?? 0
            if let contextUri = playCommand.contextUri, !contextUri.isEmpty {
                try? await play(
                    uriOrUrl: contextUri,
                    trackIndex: playCommand.index ?? -1,
                    startingAtUri: playCommand.trackUri,
                    positionMs: positionMs,
                )
            } else if let uris = playCommand.trackUris, uris.count > 1 {
                try? await playTracks(uris, positionMs: positionMs)
            } else if let single = playCommand.trackUri ?? playCommand.trackUris?.first {
                try? await play(uriOrUrl: single, trackIndex: 0, positionMs: positionMs)
            }

        case .pause:
            await pause()

        case .resume:
            await resume()

        case let .seekTo(positionMs):
            try? await audioPipeline?.seek(positionMs: positionMs)

        case .next:
            try? await advanceUserInitiated()

        case .prev:
            try? await previous()

        case let .setVolume(volume):
            await setVolume(Double(volume) / 65535.0)

        case let .setShuffle(enabled):
            await setShuffle(enabled)

        case let .setRepeat(mode):
            let repeatMode: PlaybackQueue.RepeatMode = switch mode {
            case .off: .off
            case .context: .context
            case .track: .track
            }
            await setRepeat(repeatMode)

        case let .setOptions(shuffle, repeatContext, repeatTrack):
            // librespot applies each flag that is present. Repeat-one wins over
            // repeat-context, as clients send both on for it.
            if repeatContext != nil || repeatTrack != nil {
                let track = repeatTrack ?? (repeatMode == .track)
                let context = repeatContext ?? (repeatMode == .context)
                await setRepeat(track ? .track : (context ? .context : .off))
            }
            if let shuffle {
                await setShuffle(shuffle)
            }

        case let .addToQueue(uri):
            await addToQueue(uri: uri)

        case let .setQueue(queuedUris):
            // The sender's queue is the queue now. Ignored, the report below
            // sent the old one back, and the edit snapped back where it was made.
            debugLog("LibrespotClient", "Queue set remotely: \(queuedUris.count) queued")
            playbackQueue.replaceUserQueue(with: queuedUris)
            publishQueue()

        case let .transfer(state):
            await takeOver(state)

        case .unknown:
            break
        }

        // Every command is acknowledged by a report once it has been handled,
        // as librespot's notify after `handle_request` does — also the ones
        // that change nothing a playback state would report, such as a track
        // queued while paused, which otherwise went unanswered.
        reportPlaybackToCluster()
    }

    // MARK: - State Publishing

    /// Publishes where playback is, stamped with the options and the loaded
    /// track's length as they stand now.
    ///
    /// Every state the facade sees is built here, so the options and the
    /// duration cannot be carried by one emission and dropped by the next.
    private func publishPlaybackState(
        for trackUri: String,
        playing: Bool,
        paused: Bool,
        positionMs: Int64,
    ) {
        let state = PlaybackState(
            isPlaying: playing && !paused,
            isPaused: paused,
            trackUri: trackUri,
            positionMs: positionMs,
            durationMs: knownDurationMs,
            shuffle: shuffleEnabled,
            repeatTrack: repeatMode == .track,
            repeatContext: repeatMode == .context,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
        )
        localState = state
        publish { $0.playback = state }
    }

    /// Re-emits the last playback state — used after option changes (shuffle,
    /// repeat) where only the flags moved, and after a reconnect that kept the
    /// loaded track, for the session that registered without it.
    ///
    /// Reports to the cluster as well: an option is part of the player state
    /// other devices render, so a shuffle toggled here has to show up on the
    /// phone that is watching.
    private func publishPlaybackStateRefresh() async {
        guard let current = localState else { return }
        let position = await audioPipeline?.currentPositionMs() ?? UInt64(max(0, current.positionMs))
        publishPlaybackState(
            for: current.trackUri,
            playing: current.isPlaying,
            paused: current.isPaused,
            positionMs: Int64(position),
        )
        reportPlaybackToCluster()
    }

    /// Duration of the currently loaded track, captured when it starts. The
    /// facade's playback states carry it so the seek bar knows the length.
    private var knownDurationMs: Int64 = 0

    private func publishConnectionState(
        connected: Bool,
        error: String? = nil,
        reconnectAttempt: UInt32 = 0,
    ) {
        let state = LibrespotConnectionState(
            sessionConnected: connected,
            deviceId: deviceInfo.deviceId,
            deviceName: deviceInfo.deviceName,
            reconnectAttempt: reconnectAttempt,
            lastError: error,
            connectedSinceMs: connected ? UInt64(Date().timeIntervalSince1970 * 1000) : nil,
        )
        publish { $0.connection = state }
    }

    // MARK: - Helpers

    private static func normalizedUri(_ uriOrUrl: String) -> String {
        let trimmed = uriOrUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = SpotifyAPI.parseTrackURI(trimmed) {
            return "spotify:track:\(id)"
        }
        return trimmed
    }

    private static func trackIdOnly(from uri: String) -> String? {
        guard let range = uri.range(of: "spotify:track:") else { return nil }
        return String(uri[range.upperBound...])
    }
}

// MARK: - QueueItem Convenience

extension QueueItem {
    /// A metadata-less placeholder; names hydrate through the store.
    nonisolated init(uri: String, provider: String) {
        self.init(
            id: uri,
            uri: uri,
            name: "",
            artistName: "",
            imageURLString: "",
            durationMs: 0,
            albumId: nil,
            artistId: nil,
            externalUrl: nil,
            provider: provider,
        )
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
