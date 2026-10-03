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

    /// What the HTTP requests carry (dealer, spclient), the bearer for a token
    /// login among it. Injected by the facade, which binds it to the app's
    /// keymaster grant.
    private var httpCredentials: SpotifyCredentials?

    /// The account the session plays as.
    private var usernameProvider: (@Sendable () async -> String?)?

    /// Each row's uid by its track's uri, for a context the resolver lists without them: an
    /// album. A handover names its row by uid, and pathfinder's album answer has them.
    private var contextRowUids: (@Sendable (String) async -> [(uri: String, uid: String)])?

    /// Whether this Mac may play for the account, as the last login found.
    private var streams = true

    /// The account's autoplay setting: from the last login, and flipped when another device
    /// switches it (`userAttributesMutated`).
    private var autoplay = false

    /// Consumes the current session's events; cancelled when it is torn down.
    private var sessionEvents: Task<Void, Never>?

    // MARK: - Queue & Playback Bookkeeping

    private var playbackQueue = PlaybackQueue()
    /// The resolver's metadata of the playing context, reported as `context_metadata`, as
    /// librespot does. Set with the context, and empty for a bare list.
    private var contextMetadata: [String: String] = [:]

    /// Logical Connect volume (0…65535), mirrored into player state.
    private var logicalVolume: UInt32 = 32767

    /// Tracks Spotify will not play for the account, as the app's lists said, replaced each
    /// time it tells. Next, Previous, auto-advance and the fetch-ahead step over them, and
    /// those learned below, without loading them. The context resolver's answer does not
    /// say, measured 2026-09-29, so nothing else could.
    private var listedUnplayable: Set<String> = []
    /// Tracks that failed to load here as unavailable, kept for the rest of the login.
    private var failedUnplayable: Set<String> = []

    /// Whether a track is known not to play, as of now, for the queue to step over.
    private var knownUnplayable: (String) -> Bool {
        let listed = listedUnplayable, failed = failedUnplayable
        return { listed.contains($0) || failed.contains($0) }
    }

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

    /// The other device's player state as last mirrored, rows the queue view leaves out
    /// included: a take-over of a bare list reads where its iteration ends from them. Written
    /// with the snapshot's playback, so whenever the snapshot shows mirrored playback, this is
    /// its state.
    private var mirroredRemote: PlayerState?

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
    /// comes first, falling back to a fresh bearer from `httpCredentials`. A
    /// successful token login stores its reusable credentials for next time.
    func initialize(
        httpCredentials: SpotifyCredentials,
        usernameProvider: @escaping @Sendable () async -> String?,
        contextRowUids: (@Sendable (String) async -> [(uri: String, uid: String)])? = nil,
    ) async throws {
        self.httpCredentials = httpCredentials
        self.usernameProvider = usernameProvider
        self.contextRowUids = contextRowUids
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

        let welcome: APWelcome
        do {
            welcome = try await newSession.connect(credentials: credentials, signing: httpCredentials)
        } catch LibrespotError.premiumRequired {
            // A logout that landed meanwhile has moved on to the next account, which this
            // must not be said of.
            guard lifecycleGeneration == generation else {
                throw LibrespotError.invalidState("Initialization superseded")
            }
            // Published as a free account's type is, so the app explains Premium rather
            // than offer a sign-in the accesspoint would refuse again.
            streams = false
            publishConnectionState(connected: false)
            throw LibrespotError.premiumRequired
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

        guard let httpCredentials else {
            throw LibrespotError.notInitialized
        }
        let token = try await httpCredentials.accessToken()
        guard let username = await usernameProvider?(), !username.isEmpty else {
            throw LibrespotError.authenticationFailed("No account name available for streaming login")
        }
        return .accessToken(token, username: username)
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
    /// goes in `shutdown()`'s teardown, with the pipeline it ran on.
    public func shutdownAndCleanup() async {
        await shutdown()
        listedUnplayable = []
        failedUnplayable = []
        publish {
            $0.devices = nil
            $0.queue = nil
            $0.withheld = []
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
        // The pipeline goes before anything is awaited, so that nothing still on
        // its way from it, an event or an auto-advance, can report a track once
        // the playback has been dropped.
        let pipeline = audioPipeline
        audioPipeline = nil
        pipelineEvents?.cancel()
        pipelineEvents = nil
        // The last report says what played, as it stands now. A report still
        // due would go out after the clear and say nothing plays here.
        let stopped = localState
        reportDue = false
        releaseDue = false
        stoppedToReport = nil
        clearLocalState()
        mirroredRemote = nil
        await pipeline?.stop()
        await session?.disconnect(stopped: stopReport(of: stopped))
        session = nil
        spclient = nil
        streams = true

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
            await session?.disconnect(stopped: stopReport(of: localState))
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
        guard let session, let credentials = await session.currentCredentials, let httpCredentials else { return }

        // What to come back to, read before reconnecting: the new session's
        // first cluster can arrive while it is still being set up.
        let was = localState

        do {
            _ = try await session.connect(credentials: credentials, signing: httpCredentials)

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
            if case .premiumRequired? = error as? LibrespotError {
                streams = false
            }
            publishConnectionState(connected: false, error: error.localizedDescription)
        }
    }

    /// Creates SPClient and the audio pipeline for a new session. A reconnect
    /// keeps both: neither holds the socket, and the pipeline asks the session
    /// for it each time it needs an audio key.
    private func attachTransport() async {
        guard let httpCredentials, let session else { return }

        if spclient == nil {
            spclient = await SPClient(
                credentials: httpCredentials,
                spclientHost: session.spclientHost,
                deviceId: deviceInfo.deviceId,
            )
        }

        guard let accesspoint = await session.accesspoint else { return }

        await spclient?.setCountryCode(accesspoint.lastCountryCode)
        streams = await session.streams
        autoplay = await accesspoint.autoplay ?? false

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
    ///   - trackIndex: where in the context to start; nil for its start.
    ///   - startingAtUri: the track to start on. With an index as well, the
    ///     track decides; see `PlaybackQueue.start(in:index:uri:)`.
    ///   - resumingAtUid: the context row that plays after `startingAtUri`, which plays as
    ///     queued, as a handover names it while a queued track plays; see
    ///     `PlaybackQueue.start(in:queued:resumingAt:uids:)`.
    ///   - positionMs: where in that track to start.
    ///   - paused: load it without starting playout, as a paused handover does.
    public func play(
        uriOrUrl: String,
        trackIndex: Int? = nil,
        startingAtUri: String? = nil,
        startingAtUid: String? = nil,
        resumingAtUid: String? = nil,
        positionMs: UInt64 = 0,
        paused: Bool = false,
    ) async throws {
        let uri = Self.normalizedUri(uriOrUrl)

        if uri.contains("spotify:track:") {
            try await play(contextUri: uri, tracks: [uri], startIndex: 0, positionMs: positionMs, paused: paused)
            return
        }

        // Anything else is a context that needs resolving to a track list.
        guard let spclient else {
            throw LibrespotError.notInitialized
        }

        debugLog("LibrespotClient", "Resolving context \(uri)")
        // Beside the resolve, which gives an album's rows no uids. Only an album asks.
        let rowUids = contextRowUids.map { fetch in Task { await fetch(uri) } }
        let context = try await spclient.resolveContext(uri, pageLimit: Self.pagesUpFront(of: uri))
        guard !context.tracks.isEmpty else {
            throw LibrespotError.trackNotFound("Context has no tracks")
        }

        // Waited for only where the uri cannot place the start: a queued track, whose uid names
        // the row after it, or a track the context does not list by that uri. Anywhere else the
        // uri finds the row, and the audio does not wait for a second request.
        var uids = context.uids
        let uriPlaces = resumingAtUid == nil && startingAtUri.map(context.tracks.contains) != false
        if let named = resumingAtUid ?? startingAtUid, !uriPlaces, !uids.contains(named), let rowUids {
            uids = await PlaybackQueue.rowUids(rowUids.value, of: context.tracks)
        }

        let start = startingPoint(in: context.tracks, uids: uids, index: trackIndex, uri: startingAtUri, uid: startingAtUid, resumingAt: resumingAtUid)
        try await play(contextUri: uri, tracks: start.tracks, uids: start.uids, startIndex: start.index, metadata: context.metadata, nextPage: context.nextPageUrl, restrictions: context.restrictions, playingQueued: start.queued, positionMs: positionMs, paused: paused)
        // Otherwise the rows take them when they come: a jump that names a row's uid then
        // reaches that row, not a queued copy of its track.
        if !uids.contains(where: { $0 != nil }), let rowUids {
            Task { await self.adoptRowUids(rowUids, ofContext: uri) }
        }
    }

    /// Gives the playing context's rows the uids `rowUids` lists, and tells the app and other
    /// devices; see `PlaybackQueue.adoptRowUids(_:ofContext:)`.
    private func adoptRowUids(_ rowUids: Task<[(uri: String, uid: String)], Never>, ofContext uri: String) async {
        guard await playbackQueue.adoptRowUids(rowUids.value, ofContext: uri) else { return }
        debugLog("LibrespotClient", "Rows of \(uri) named by uid")
        // The queue only: uids do not change the next track, and announcing it during a load
        // could cancel a fetched-ahead copy of the track being loaded. A load under way reports
        // the uids with its own track.
        let queue = queueState
        publish { $0.queue = queue }
        if let localState, localState.trackUri == playbackQueue.currentUri {
            reportPlaybackToCluster()
        }
    }

    /// Plays a list of tracks that no album or playlist names, starting where `trackIndex` and
    /// `startingAtUri` say, or a handover's rows: `uids` beside the tracks, and the row a queued
    /// track goes on to, `resumingAtUid`, as `play(uriOrUrl:)` takes them; see `startingPoint`.
    /// A single track is its own context, as `play(uriOrUrl:)` makes it.
    public func playTracks(
        _ uris: [String],
        uids: [String?] = [],
        trackIndex: Int? = nil,
        startingAtUri: String? = nil,
        startingAtUid: String? = nil,
        resumingAtUid: String? = nil,
        positionMs: UInt64 = 0,
        paused: Bool = false,
    ) async throws {
        let start = startingPoint(
            in: uris.map(Self.normalizedUri),
            uids: uids,
            index: trackIndex,
            uri: startingAtUri.map(Self.normalizedUri),
            uid: startingAtUid,
            resumingAt: resumingAtUid,
        )
        guard let first = start.tracks.first else {
            throw LibrespotError.invalidState("No tracks to play")
        }

        let contextUri = start.tracks.count == 1 && first.contains("spotify:track:") ? first : ""
        try await play(contextUri: contextUri, tracks: start.tracks, uids: start.uids, startIndex: start.index, playingQueued: start.queued, positionMs: positionMs, paused: paused)
    }

    /// Where a context or a list starts, from what the caller or a handover named:
    /// - a queued track playing, and the row the context goes on with after it, where the
    ///   context has that row; see `PlaybackQueue.start(in:queued:resumingAt:uids:)`;
    /// - otherwise the row or the track named; see `PlaybackQueue.start(in:index:uri:uid:uids:)`;
    /// - with nothing named, as by Play on an album or Play Tracks under search, its first track
    ///   that plays.
    private func startingPoint(
        in tracks: [String],
        uids: [String?],
        index: Int?,
        uri: String?,
        uid: String?,
        resumingAt resumeUid: String?,
    ) -> (tracks: [String], uids: [String?], index: Int, queued: String?) {
        if let resumeUid, let uri, let start = PlaybackQueue.start(in: tracks, queued: uri, resumingAt: resumeUid, uids: uids) {
            return start
        }
        let start = PlaybackQueue.start(in: tracks, index: index, uri: uri, uid: uid, uids: uids)
        let row = index == nil && uri == nil ? firstPlayable(in: start.tracks) : start.index
        return (start.tracks, start.uids, row, nil)
    }

    /// Song radio for a seed track, resolved through its station context.
    public func playRadio(trackUri: String) async throws {
        guard let id = SpotifyAPI.parseTrackURI(trackUri) ?? Self.trackIdOnly(from: trackUri) else {
            throw LibrespotError.trackNotFound("Not a track uri")
        }
        try await play(uriOrUrl: "spotify:station:track:\(id)")
    }

    // MARK: - Playback: Transport

    public func pause() async {
        await audioPipeline?.pause()
    }

    /// Resumes what is loaded here. With nothing loaded while the snapshot
    /// shows a track, that track is another device's, mirrored, and nobody
    /// plays it: resuming then takes it over from where it was left, as Play
    /// does on Spotify's own clients, instead of resuming an empty pipeline.
    /// It is read as a handover would carry it (`takeOverState`) and played as
    /// one is, from the position the mirror last showed: with no device active,
    /// nothing has played on since.
    public func resume() async throws {
        guard localState == nil, latest.withLock({ $0.playback }) != nil,
              let state = mirroredRemote.flatMap(Self.takeOverState), let track = state.currentTrackUri
        else {
            await audioPipeline?.resume()
            return
        }
        let positionMs = UInt64(max(0, state.positionAsOfTimestamp))
        debugLog("LibrespotClient", "Taking over the mirrored \(track) in \(state.contextUri.isEmpty ? "a list of tracks" : state.contextUri) at \(positionMs)ms")
        try await continuePlayback(of: state, positionMs: positionMs, paused: false)
    }

    public func seek(positionMs: UInt32) async throws {
        try await audioPipeline?.seek(positionMs: UInt64(positionMs))
    }

    public func next() async throws {
        try await advanceUserInitiated()
    }

    public func previous() async throws {
        defer { publishQueue() }

        if let previous = playbackQueue.back(skipping: knownUnplayable) {
            try await loadAndPlay(previous, going: .backward)
        } else {
            // Nowhere back: restart the current track, like every other client.
            try await audioPipeline?.seek(positionMs: 0)
        }
    }

    /// Plays `uri` from the next tracks this client publishes, the row `uid`
    /// names, or else the copy nearest `position`, without resolving the context
    /// again. See `PlaybackQueue.skip(toUpcoming:uri:uid:)`.
    ///
    /// Throws when the track is no longer listed: the caller has already moved
    /// the display to the start of a track, and only a failure takes that back.
    public func skip(toNext position: Int?, uri: String, uid: String?) async throws {
        defer { publishQueue() }
        guard let next = playbackQueue.skip(toUpcoming: position, uri: uri, uid: uid) else {
            throw LibrespotError.trackNotFound("\(uri) is no longer in the queue")
        }
        try await loadAndPlay(next)
    }

    /// Plays `uri` from the previous tracks this client publishes, as Previous
    /// would, pressed that many times. See `PlaybackQueue.stepBack(toRecent:uri:)`.
    /// Throws as `skip(toNext:uri:)` does.
    public func skip(toPrevious index: Int, uri: String, uid: String?) async throws {
        defer { publishQueue() }
        guard let previous = playbackQueue.stepBack(toRecent: index, uri: uri, uid: uid) else {
            throw LibrespotError.trackNotFound("\(uri) is no longer in the queue")
        }
        try await loadAndPlay(previous, going: .backward)
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
        return try await spclient.resolveContext(normalized, pageLimit: Self.pagesUpFront(of: normalized)).tracks
    }

    /// How many of a context's pages are fetched before it plays or is queued: one of a station's,
    /// which names pages without end; following them cost about 0.4 s before a station played
    /// (2026-10-02), and the rest come as its rows run out (`lineUpNextPage`). Any other context
    /// comes whole, as a 150-track playlist did in one page, for shuffle and repeat to have all
    /// of its rows.
    nonisolated static func pagesUpFront(of uri: String) -> Int {
        uri.hasPrefix("spotify:station:") ? 1 : 10
    }

    /// Switches shuffle, unless the context does not allow it, as librespot refuses it: a station,
    /// whose rows grow a page at a time, would mix those played long ago back in. The report
    /// every remote command is answered with tells the sender it stayed off.
    public func setShuffle(_ enabled: Bool) async {
        guard !enabled || playbackQueue.restrictions.allowsShuffle else {
            debugLog("LibrespotClient", "Shuffle refused: \(playbackQueue.restrictions.togglingShuffle)")
            return
        }
        playbackQueue.setShuffle(enabled)
        // Shuffle reorders what comes next, so the queue views move with it.
        publishQueue()
        await publishPlaybackStateRefresh()
    }

    /// Repeat leaves the queue's order alone — only the flags move, so this
    /// refreshes the playback state and nothing else. A mode the context does not allow is
    /// refused, as `setShuffle` refuses shuffle: a station's repeat would play every page again.
    func setRepeat(_ mode: PlaybackQueue.RepeatMode) async {
        guard playbackQueue.restrictions.allows(mode) else {
            debugLog("LibrespotClient", "Repeat \(mode) refused")
            return
        }
        playbackQueue.setRepeat(mode)
        announceNextTrack()
        await publishPlaybackStateRefresh()
    }

    /// Tells the pipeline what auto-advance will play, so it can fetch it
    /// before the current track ends. Under repeat-one that is the same track,
    /// which the pipeline already holds.
    private func announceNextTrack() {
        let next = playbackQueue.repeatMode == .track
            ? playbackQueue.currentUri
            : playbackQueue.upcomingPlayable(skipping: knownUnplayable)
        lineUpNextPage()
        if next == nil {
            lineUpAutoplay()
        }
        Task { [audioPipeline] in await audioPipeline?.setNextTrack(next) }
    }

    /// How few rows may be left before the context's next page is fetched, as librespot fetched a
    /// station's under 5.
    private static let rowsBeforeNextPage = 5

    /// The next page being fetched, so it is asked for once at a time.
    private var nextPageFetch: String?

    /// Fetches the context's next page as its rows run out: a station's, resolved a page at a time
    /// (`pagesUpFront`). Its rows are then listed, reported and fetched ahead before the page
    /// playing ends, as autoplay's are, and other devices' lists of what comes next do not run
    /// dry. The url stays in the queue until its page comes, so a failed fetch is asked again with
    /// the next track, and autoplay waits for it.
    private func lineUpNextPage() {
        guard let url = playbackQueue.nextPageUrl, nextPageFetch == nil, localState != nil, let spclient,
              playbackQueue.upcoming(limit: Self.rowsBeforeNextPage).count < Self.rowsBeforeNextPage
        else { return }
        nextPageFetch = url
        Task {
            defer { nextPageFetch = nil }
            let page: SPClient.ResolvedContext
            do {
                page = try await spclient.resolvePage(url)
            } catch {
                debugLog("LibrespotClient", "Next page of \(playbackQueue.contextUri) failed: \(error.localizedDescription)")
                return
            }
            // Still playing here, the context that named this page. A page without rows ends the
            // paging, rather than asking for the one it names at once.
            guard localState != nil, playbackQueue.nextPageUrl == url else { return }
            playbackQueue.appendPage(page.tracks, uids: page.uids, next: page.tracks.isEmpty ? nil : page.nextPageUrl)
            debugLog("LibrespotClient", "Next page of \(playbackQueue.contextUri) lined up: \(page.tracks.count) track(s)")
            publishQueue()
            reportPlaybackToCluster()
        }
    }

    /// Asks for autoplay when nothing comes after the track playing here, with the account's
    /// autoplay on and nothing to repeat: its tracks are then listed, reported and fetched ahead
    /// before the context ends, as librespot's `add_autoplay_resolving_when_required` has them. A
    /// station is followed by none, as under go-librespot, and a bare list has no context to ask
    /// for; a context that names another page waits for it (`lineUpNextPage`).
    ///
    /// Asked from `announceNextTrack`, and again once the first track here reports, which the
    /// queue's publish can come before.
    private func lineUpAutoplay() {
        let contextUri = playbackQueue.contextUri
        guard autoplay, localState != nil, playbackQueue.repeatMode == .off, !playbackQueue.autoplayAsked,
              !contextUri.isEmpty, !contextUri.hasPrefix("spotify:station:"), playbackQueue.nextPageUrl == nil, let spclient,
              playbackQueue.upcomingPlayable(skipping: knownUnplayable) == nil
        else { return }
        playbackQueue.markAutoplayAsked()
        let seed = playbackQueue.autoplaySeed
        Task {
            let station: SPClient.ResolvedContext
            do {
                station = try await spclient.resolveAutoplay(contextUri: contextUri, recentTrackUris: seed)
            } catch {
                debugLog("LibrespotClient", "Autoplay for \(contextUri) failed: \(error.localizedDescription)")
                return
            }
            // Still playing here, the context it was asked for, with nothing after the track
            // playing, and still wanted: any of it may have changed meanwhile.
            guard autoplay, localState != nil, playbackQueue.repeatMode == .off, playbackQueue.contextUri == contextUri, playbackQueue.autoplayAsked,
                  playbackQueue.autoplayStart == nil, playbackQueue.upcomingPlayable(skipping: knownUnplayable) == nil
            else { return }
            playbackQueue.appendAutoplay(station.tracks, uids: station.uids, from: station.uri)
            debugLog("LibrespotClient", "Autoplay lined up after \(contextUri): \(station.tracks.count) track(s)")
            publishQueue()
            reportPlaybackToCluster()
        }
    }

    /// The account's autoplay switched on another device. Switched off, autoplay's rows go
    /// unless one plays; either way it may be asked for again.
    private func setAutoplay(_ enabled: Bool) {
        autoplay = enabled
        debugLog("LibrespotClient", "Autoplay \(enabled ? "on" : "off")")
        playbackQueue.dropAutoplay()
        // While another device plays, the Queue section shows its queue, not this one.
        guard localState != nil else { return }
        publishQueue()
    }

    /// A track Spotify withholds, found out by loading it or by fetching it ahead: the queue
    /// steps over it from now on, and the app greys it, since no list said so.
    private func markUnplayable(_ uri: String) {
        failedUnplayable.insert(uri)
        let withheld = failedUnplayable
        publish { $0.withheld = withheld }
    }

    /// Replaces the tracks the app's lists said will not play.
    public func setUnplayable(_ uris: Set<String>) {
        guard uris != listedUnplayable else { return }
        listedUnplayable = uris
        // The track fetched ahead may be one of them.
        announceNextTrack()
    }

    /// Where a list starts when nobody named a track: its first not known to be unplayable,
    /// or its first if it has none.
    private func firstPlayable(in tracks: [String]) -> Int {
        let isUnplayable = knownUnplayable
        return tracks.firstIndex { !isUnplayable($0) } ?? 0
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

    nonisolated var positionMsCached: UInt64 {
        positionCache.withLock { $0 }
    }

    /// Whether this device is the cluster's active one.
    nonisolated var isActiveDeviceFlagValue: Bool {
        latest.withLock { $0.activeDeviceId == deviceInfo.deviceId }
    }

    /// Position cache, fed by the pipeline's position ticks and by every position
    /// local playback publishes (`publishPlaybackState`), and read from anywhere.
    /// Ticks alone left it at the last stop's position for the quarter second
    /// before a load's first tick, long enough for the drift check to pull the bar
    /// back there (`plans/done/seek-bar-behind-after-a-handover.md`).
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

    /// Plays from a new context. The queue goes out with the track when the load announces it,
    /// and is published again afterwards, as the skips do: announcing the next track any sooner
    /// would cancel a fetched-ahead copy of this one.
    ///
    /// - Parameters:
    ///   - queued: a track to play as queued, after the context's start row.
    ///   - autoplay: autoplay's rows to play from, after the context's start row, or after
    ///     `queued` when one plays; see `continueAutoplay`.
    private func play(
        contextUri: String,
        tracks: [String],
        uids: [String?] = [],
        startIndex: Int,
        metadata: [String: String] = [:],
        nextPage: String? = nil,
        restrictions: Restrictions = .init(),
        playingQueued queued: String? = nil,
        playingAutoplay autoplay: (tracks: [String], uids: [String?], station: String?)? = nil,
        positionMs: UInt64,
        paused: Bool,
    ) async throws {
        contextMetadata = metadata
        playbackQueue.setContext(uri: contextUri, tracks: tracks, uids: uids, startIndex: startIndex, nextPage: nextPage, restrictions: restrictions)
        // Before the load, so the row before it never shows as the one playing.
        if let autoplay, !autoplay.tracks.isEmpty {
            playbackQueue.playAutoplay(autoplay.tracks, uids: autoplay.uids, from: autoplay.station, after: queued)
        } else if let queued {
            playbackQueue.playQueued(queued)
        }
        defer { publishQueue() }
        try await loadCurrentTrack(positionMs: positionMs, paused: paused)
    }

    private func loadCurrentTrack(positionMs: UInt64 = 0, paused: Bool = false) async throws {
        guard let uri = playbackQueue.currentUri ?? playbackQueue.advance() else {
            throw LibrespotError.invalidState("Nothing to play")
        }
        try await loadAndPlay(uri, positionMs: positionMs, paused: paused)
    }

    /// Starts audio for a uri the queue has just moved to, and goes on past it in `direction`
    /// while Spotify withholds what it reaches; see `AutoAdvance`. Any other failure gives
    /// playback up: the pipeline tears the previous track down when it announces this one, or
    /// when this one fails before that, so a failed load leaves nothing playing.
    ///
    /// Deliberately separate from `play`: advancing through an existing queue
    /// must not rebuild it.
    ///
    /// - Parameters:
    ///   - positionMs: where in `uri` to start. A track it goes on to starts at the top.
    ///   - paused: load without starting playout, as a paused handover does.
    ///   - direction: back for Previous and a jump to a previous track.
    private func loadAndPlay(
        _ uri: String,
        positionMs: UInt64 = 0,
        paused: Bool = false,
        going direction: AutoAdvance.Direction = .forward,
    ) async throws {
        // The app routes plays elsewhere for such an account; every local start passes here
        // (auto-advance only follows one), so anything it misses is refused with the reason,
        // not a raw error from the audio key or the CDN.
        guard streams else {
            throw LibrespotError.premiumRequired
        }
        let outcome = await AutoAdvance.run(
            from: uri,
            in: playbackQueue,
            going: direction,
            isUnplayable: knownUnplayable,
            // The position is the named track's, which the run may have stepped over unloaded.
            load: { try await self.startTrack($0, positionMs: $0 == uri ? positionMs : 0, paused: paused) },
            skipped: { self.reportSkipped($0, name: $1) },
        )
        switch outcome {
        case .playing:
            break
        case .superseded:
            // A newer load took over while this one waited, and publishes its
            // own state; clearing it here would erase that.
            throw CancellationError()
        case .queueEnded where direction == .forward:
            // Past the context's end, as a Next on its last track.
            await rewindContext()
        case .queueEnded:
            // Nothing further back plays: on from the withheld track, as Next would, which
            // gets back to the track Previous was pressed on.
            try await advanceUserInitiated()
        case let .stopped(error):
            playbackFailed(error)
            throw error
        }
    }

    /// One attempt at a track. The bar and other devices hear of it when the pipeline announces
    /// it, once its metadata has said Spotify has a file for it (`handlePipelineState`), so a
    /// withheld track is passed over without ever being shown.
    ///
    /// `loadAndPlay` runs every load through it and gives up once, after its
    /// last attempt, so other devices do not see the Mac stop and start again
    /// between two tracks.
    private func startTrack(_ uri: String, positionMs: UInt64 = 0, paused: Bool = false) async throws {
        guard let audioPipeline else {
            throw LibrespotError.notInitialized
        }

        do {
            try await audioPipeline.playTrack(uri: uri, positionMs: positionMs, paused: paused)
        } catch {
            if case LibrespotError.trackUnavailable = error {
                markUnplayable(uri)
            }
            throw error
        }
    }

    /// Auto-advance at end of track.
    private func handleEndOfTrack(_ uri: String) {
        Task {
            // A skip that landed between the event and this task has moved on already:
            // advancing again passed over its track, and repeat-one played the old one again
            // under the new one's queue.
            guard uri == playbackQueue.currentUri else { return }
            if playbackQueue.repeatMode == .track {
                await autoAdvance(to: uri)
                return
            }
            if let upcoming = playbackQueue.advance() {
                await autoAdvance(to: upcoming)
            } else {
                await rewindContext()
            }
            // The advance moved current/history/next; queue views need it.
            publishQueue()
        }
    }

    /// Plays what auto-advance moved to. Nobody is waiting for its errors:
    /// `loadAndPlay` publishes each skip, and a stop, for the now-playing bar.
    private func autoAdvance(to uri: String) async {
        do {
            try await loadAndPlay(uri)
        } catch is CancellationError {
            // A newer load took over, and it reports for itself.
        } catch LibrespotError.premiumRequired {
            // Refused before any load, with the ended track still held: the account stopped
            // streaming here since it started, as a reconnect can find.
            playbackFailed(LibrespotError.premiumRequired)
        } catch {
            debugLog("LibrespotClient", "Auto-advance stopped: \(error.localizedDescription)")
        }
    }

    /// The bar says a track was passed over because Spotify withholds it.
    private func reportSkipped(_ uri: String, name: String) {
        debugLog("LibrespotClient", "Skipping \(uri), \(name): not available")
        interrupt(String(localized: "playback.skipped_unavailable \(name)"))
    }

    /// Manual skip: always moves somewhere, wrapping past the end when repeat
    /// allows and rewinding the context otherwise.
    private func advanceUserInitiated() async throws {
        defer { publishQueue() }

        // A manual skip moves even under repeat-one; only auto-advance honors it.
        if let upcoming = playbackQueue.move(by: { playbackQueue.advance(respectingRepeat: false) }, skipping: knownUnplayable) {
            try await loadAndPlay(upcoming)
        } else {
            await rewindContext()
        }
    }

    /// The queue has run out with nothing to repeat: back to the first track
    /// of the context that plays, loaded and paused at its start, as librespot's
    /// `handle_stop` leaves it. Other devices show a stopped player on that
    /// track, and their play button plays it.
    ///
    /// This used to stop and report no player state at all, while the device
    /// stayed the active one. The web player read that as nothing new and
    /// went on showing this Mac playing the last second of the last track,
    /// its play button sending pause.
    private func rewindContext() async {
        let isUnplayable = knownUnplayable
        // Nothing in the context plays: a load would go past its end again, and back here. A
        // track found out on the way has said so; an album or a playlist says it of itself.
        guard let first = playbackQueue.ownTracks.firstIndex(where: { !isUnplayable($0) }) else {
            await audioPipeline?.stop()
            if let contextName = contextMetadata.contextName {
                playbackFailed(LibrespotError.trackUnavailable(name: contextName))
            } else {
                releasePlayback()
            }
            return
        }
        debugLog("LibrespotClient", "End of the context; back to its first track, paused")
        playbackQueue.rewind(to: first)
        // A failure is reported by `loadAndPlay`, and there is no caller to
        // throw it to.
        try? await loadCurrentTrack(paused: true)
    }

    /// Publishes the queue, with the context it plays from, and tells the pipeline which
    /// track to fetch ahead.
    ///
    /// A load publishes the queue itself, with its track, when the pipeline announces it; see
    /// `handlePipelineState`. The fetch ahead
    /// waits until the load is done: announcing the next track before it would cancel a
    /// fetched-ahead copy of the very track being loaded.
    private func publishQueue() {
        announceNextTrack()
        let queue = queueState
        publish { $0.queue = queue }
    }

    /// The queue as the app sees it: the context, the current track, and the tracks either
    /// side of it.
    private var queueState: QueueState {
        QueueState(
            contextUri: playbackQueue.contextUri,
            currentTrack: playbackQueue.current,
            nextTracks: playbackQueue.upcoming(),
            previousTracks: playbackQueue.recent(),
            contextName: contextMetadata.contextName,
        )
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
            case let .withheldAhead(uri):
                markUnplayable(uri)
                // The fetch ahead moves on to the track after it. A failed load does not
                // announce: the run it is part of announces once it has moved the queue, and an
                // announcement from mid-run could land after that one.
                announceNextTrack()
            case let .error(error):
                debugLog("LibrespotClient", "Audio pipeline error: \(error.localizedDescription)")
                playbackFailed(error)
            }
        }
    }

    /// The local player holds nothing any more.
    private func clearLocalState() {
        localState = nil
        publish { $0.playback = nil }
    }

    /// Nothing plays here any more, over `error`: the local state goes, the
    /// device lets go of the active role, and the now-playing bar says why.
    ///
    /// The one place a failure ends playback, whoever started it. A play the
    /// app started shows the thrown error too, and `errorMessage` takes the
    /// same text only once.
    private func playbackFailed(_ error: any Error) {
        releasePlayback()
        interrupt(error.localizedDescription)
    }

    /// Ends playback here: the local state goes, and the next report says where it stopped,
    /// while this is still the active device, then lets go of the role and reports that
    /// nothing plays here.
    ///
    /// Clearing the local state alone told the cluster nothing: the last
    /// report stood, and on 2026-09-29 every heartbeat after a failed load
    /// went on telling the web player this Mac was playing the track at 0ms.
    /// Letting go without saying where left it standing too: "playing", at the position of
    /// the last change, which whatever mirrored the cluster showed, this Mac included (6 s
    /// back, in a failure faked 10 s into a track).
    ///
    /// Queued with the other reports rather than awaited: a failure is said at once, not after
    /// a PutState that waits out its timeout when the network is why playback failed, and a
    /// start that follows is reported after the release, not before it.
    private func releasePlayback() {
        releaseDue = true
        // A second release before the first went out keeps the first's position.
        stoppedToReport = stopReport(of: localState) ?? stoppedToReport
        clearLocalState()
        reportPlaybackToCluster()
    }

    /// Tells the now-playing bar that playback went past a track, or stopped.
    private func interrupt(_ message: String) {
        publish {
            $0.interruption = PlaybackInterruption(
                message: message,
                sequence: ($0.interruption?.sequence ?? 0) + 1,
            )
        }
    }

    private func handlePipelineState(_ state: AudioPipeline.AudioPlaybackState) async {
        switch state {
        case .idle:
            break // end-of-track and stop own the nil transition

        case let .loading(trackUri, positionMs, paused, durationMs):
            // A newer start moved the queue on while this one's metadata was asked for, and it
            // announces its own.
            guard trackUri == playbackQueue.currentUri else { return }
            // Its own length, or zero until the load has it: never the previous track's.
            knownDurationMs = durationMs
            // With the queue that moved to it, in one snapshot, so the store never holds the new
            // track in the old lists.
            publishPlaybackState(for: trackUri, playing: !paused, paused: paused, positionMs: Int64(clamping: positionMs), queue: queueState)

        case let .playing(trackUri):
            let position = await audioPipeline?.currentPositionMs() ?? 0
            let duration = await audioPipeline?.currentDurationMs ?? 0
            // Torn down or replaced while this waited: the track is no one's now. Or a skip
            // moved the queue on to another while this waited, which it announces.
            guard !Task.isCancelled, trackUri == playbackQueue.currentUri else { return }
            // Every load ends here or in `.paused`. A track that followed on without a gap is
            // never `.loading`, so its length and its queue go out here too.
            knownDurationMs = duration
            publishPlaybackState(for: trackUri, playing: true, paused: false, positionMs: Int64(position), queue: queueState)

        case let .paused(trackUri):
            let position = await audioPipeline?.currentPositionMs() ?? 0
            let duration = await audioPipeline?.currentDurationMs ?? 0
            guard !Task.isCancelled, trackUri == playbackQueue.currentUri else { return }
            knownDurationMs = duration
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
    /// Whether the next report lets go of the active role first; see `releasePlayback`.
    private var releaseDue = false
    /// Where playback stopped, for that release to say; nil when there is nothing to say.
    private var stoppedToReport: SpircController.SpircPlayerState?
    /// Sends the reports in turn; nil while none is going out.
    private var reporting: Task<Void, Never>?

    private func sendPlaybackReport() async {
        let releasing = releaseDue
        let stopped = stoppedToReport
        releaseDue = false
        stoppedToReport = nil
        guard let session else { return }
        if releasing {
            await session.releaseLocalPlayback(stopped: stopped)
        }
        guard let current = localState else {
            await session.reportLocalPlayerState(nil, active: false)
            return
        }

        await session.reportLocalPlayerState(spircState(of: current), active: current.isPlaying)
    }

    /// What a deliberate disconnect hands Spirc to report as stopped:
    /// `current`, unless the session is down, where a PutState could only
    /// wait out its timeout.
    private func stopReport(of current: PlaybackState?) -> SpircController.SpircPlayerState? {
        guard let current, currentConnectionState?.sessionConnected == true else { return nil }
        return spircState(of: current)
    }

    /// `current` as Spirc reports it, with the queue around it.
    private func spircState(of current: PlaybackState) -> SpircController.SpircPlayerState {
        SpircController.SpircPlayerState(
            isPlaying: current.isPlaying,
            isPaused: current.isPaused,
            trackUri: current.trackUri.isEmpty ? nil : current.trackUri,
            positionMs: UInt64(max(0, current.positionMs)),
            // The state's own: the pipeline's is the previous track's while a new one loads, and
            // went out as the new one's, which the web player then showed until a heartbeat.
            durationMs: UInt64(max(0, current.durationMs)),
            shuffle: current.shuffle,
            repeatMode: current.repeatTrack ? .track : (current.repeatContext ? .context : .off),
            // The moment the position was read, not now: a republish of an
            // older state would otherwise tell other devices the track jumped
            // back to where it was when that state was taken.
            timestamp: UInt64(max(0, current.timestampMs)),
            contextUri: playbackQueue.contextUri,
            contextMetadata: contextMetadata,
            restrictions: playbackQueue.restrictions,
            contextIndex: playbackQueue.reportedIndex,
            autoplayContextUri: playbackQueue.autoplayContextUri,
            trackProvider: playbackQueue.currentProvider,
            trackUid: playbackQueue.current?.uid,
            sessionRow: playbackQueue.sessionRow,
            nextTracks: playbackQueue.upcoming(rounds: .asReported),
            previousTracks: playbackQueue.recent(),
        )
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
            // id is nobody: our own disconnect leaves one when the session drops,
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
            // Measured 2026-10-01: on an album's last track with repeat off the web player lists
            // only hidden rows, and names no reason not to skip next. A librespot made to name
            // one greyed Next here (2026-10-02).
            canSkipNext: !remote.disallowsSkippingNext,
            // The web player playing a station names it, and greys its own Shuffle, and
            // librespot does while it plays autoplay (2026-10-02).
            canShuffle: remote.restrictions.allowsShuffle,
        )
        let queue = Self.mirroredQueue(of: remote)
        mirroredRemote = remote
        publish {
            $0.playback = playback
            $0.queue = queue
        }
    }

    /// Another device's mirrored playback as a handover of it would carry it, for Play on this
    /// Mac to take it over as `takeOver` takes a handover: the context, its options, the track,
    /// the queued rows ahead, and while a queued track plays, the row the context goes on with.
    ///
    /// A bare list has no uri to resolve, so the rows are the list: those played before the
    /// current one, since the last `spotify:delimiter`, the current one, and those after it up to
    /// the next, where with repeat on the list starts again as its next iteration. Taken whole,
    /// with the iterations, the list held its tracks two or three times, and local repeat looped
    /// that. The tracks before go in so repeat comes back to them. Queued rows are not the
    /// list's, and rows the sender hides are left out, as `mirroredQueue` leaves them out.
    ///
    /// A queued track playing is not one of the list's rows: it plays as queued, and the list
    /// goes on with the row after it (`plans/done/queued-track-handover-in-a-bare-list.md`).
    /// With no row after it, it goes into the list where it plays.
    nonisolated static func takeOverState(of remote: PlayerState) -> TransferState? {
        guard let current = remote.track, !current.uri.isEmpty else { return nil }
        let before = remote.prevTracks.reversed().prefix { $0.uri != PlaybackQueue.delimiterUri }.reversed()
            .filter { isShown($0) && $0.provider != "queue" }
        let ahead = thisRound(of: remote.nextTracks).filter(isShown)
        let listed = ahead.filter { $0.provider != "queue" }
        let resumingAt = current.provider == "queue" ? listed.first.flatMap(rowUid) : nil
        let rows = before + (resumingAt == nil ? [current] : []) + listed
        // The row the session stands on: the current one, or the one a queued track goes on with.
        let sessionRow = resumingAt == nil ? current : listed.first

        var state = TransferState()
        state.contextUri = remote.contextUri
        state.contextTrackUris = rows.map(\.uri)
        state.contextTrackUids = rows.map(rowUid)
        state.currentTrackUri = current.uri
        state.currentRow = resumingAt == nil ? before.count : nil
        state.currentTrackUid = current.provider == "queue" ? nil : rowUid(current)
        state.queuedTrackUris = ahead.filter { $0.provider == "queue" }.map(\.uri)
        state.contextResumeUid = resumingAt
        state.playsQueuedTrack = resumingAt != nil
        state.continuesAutoplay = sessionRow?.provider == "autoplay"
        state.autoplayContextUri = sessionRow?.metadata["context_uri"].flatMap { $0.hasPrefix("spotify:station:") ? $0 : nil }
        state.shuffle = remote.options.shufflingContext
        state.repeatContext = remote.options.repeatingContext
        state.repeatTrack = remote.options.repeatingTrack
        state.positionAsOfTimestamp = remote.positionAsOfTimestamp
        state.timestamp = remote.timestamp
        state.isPaused = remote.isPaused
        return state
    }

    /// A row's uid, or none for one sent without; proto3 sends that as "".
    private nonisolated static func rowUid(_ track: ProvidedTrack) -> String? {
        track.uid.isEmpty ? nil : track.uid
    }

    /// The rows ahead up to the first `spotify:delimiter`, after which a device under repeat
    /// lists its context again; the take-over and the mirror read one round the same way.
    private nonisolated static func thisRound(of rows: [ProvidedTrack]) -> ArraySlice<ProvidedTrack> {
        rows.prefix { $0.uri != PlaybackQueue.delimiterUri }
    }

    /// Whether the sending device shows a row in its own queue; see `mirroredQueue(of:)`. Its
    /// delimiters are hidden too.
    private nonisolated static func isShown(_ track: ProvidedTrack) -> Bool {
        !track.isHidden
    }

    /// The queue another device reports, as the Queue section shows it.
    ///
    /// The context goes with it, as for local playback: the queue's heading and a
    /// double-click on one of its rows play from it. Without it they named the last local
    /// context.
    ///
    /// Rows the sender marks hidden are left out, as its own queue leaves them out. After a
    /// context's last track the web player sends a `spotify:delimiter` row, then the context
    /// again as its next iteration, for repeat to play: with repeat off every row from the
    /// delimiter on is `hidden`, with repeat on only the delimiters are. So the context's rows
    /// after the first delimiter are left out, hidden or not: one round, as this Mac's own queue
    /// lists (`PlaybackQueue.Rounds.one`). Rows after it that are not the context stay: librespot
    /// lists its autoplay rows there, shown, where a phone lists them straight after the
    /// context's last row (measured 2026-10-02).
    nonisolated static func mirroredQueue(of remote: PlayerState) -> QueueState {
        let item: (ProvidedTrack) -> QueueItem = { QueueItem(uri: $0.uri, provider: $0.provider, uid: rowUid($0)) }
        let round = thisRound(of: remote.nextTracks)
        let beyond = remote.nextTracks.dropFirst(round.count).filter { $0.provider != "context" && $0.uri != PlaybackQueue.delimiterUri }
        let ahead = round + beyond
        return QueueState(
            contextUri: remote.contextUri,
            currentTrack: remote.track.map(item),
            nextTracks: ahead.filter(isShown).map(item),
            // In play order, as the cluster keeps them and the local queue
            // publishes them.
            previousTracks: remote.prevTracks.filter(isShown).map(item),
            contextName: remote.contextMetadata.contextName,
        )
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

        do {
            try await continuePlayback(of: transfer, positionMs: positionMs, paused: transfer.isPaused)
        } catch is CancellationError {
            // A newer load took over, and it reports for itself.
        } catch {
            // Let the role go again, or the cluster goes on showing this device
            // as the one playing — over silence, with every control sent here.
            debugLog("LibrespotClient", "Transfer failed to load: \(error.localizedDescription)")
            releasePlayback()
        }
    }

    /// Plays what another device had, handed over or taken over from its mirror: its options,
    /// its queue, and the same context or list at the same track. A queued track plays as queued,
    /// and the context goes on with the row the other device had next.
    private func continuePlayback(of state: TransferState, positionMs: UInt64, paused: Bool) async throws {
        // Into the queue as sent, where the context playing now does not refuse them: the one
        // taken over turns off what it does not allow.
        playbackQueue.setShuffle(state.shuffle)
        playbackQueue.setRepeat(state.repeatTrack ? .track : (state.repeatContext ? .context : .off))
        // Before loading, so the first report and the next-track fetch already
        // see the other device's queue, and none left over from before.
        playbackQueue.replaceUserQueue(with: state.queuedTrackUris)

        if state.continuesAutoplay {
            try await continueAutoplay(of: state, positionMs: positionMs, paused: paused)
        } else if !state.contextUri.isEmpty {
            try await play(
                uriOrUrl: state.contextUri,
                startingAtUri: state.currentTrackUri,
                startingAtUid: state.currentTrackUid,
                resumingAtUid: state.contextResumeUid,
                positionMs: positionMs,
                paused: paused,
            )
        } else {
            // Started from a bare list of uris, so the list is all there is.
            try await playTracks(
                state.contextTrackUris,
                uids: state.contextTrackUids,
                trackIndex: state.currentRow,
                startingAtUri: state.currentTrackUri,
                startingAtUid: state.currentTrackUid,
                resumingAtUid: state.contextResumeUid,
                positionMs: positionMs,
                paused: paused,
            )
        }
    }

    /// Goes on with another device's autoplay: the context it followed, standing on its last
    /// row, and autoplay's rows from the session's (`PlaybackQueue.playAutoplay`). A queued track
    /// playing plays first, as queued, and autoplay goes on with the row it names after it.
    ///
    /// The rows are the other device's from the session's on, where it sent them: a mirror's from
    /// `currentRow`, or the row a uid names, as in the handover this Mac writes. A phone's and
    /// the web player's handovers send none, so a station is asked for beside the context, seeded
    /// with the track and what the handover sent of the context.
    ///
    /// A phone and the web player hand autoplay over with the station as the context,
    /// `spotify:station:album:<id>`, which gets no autoplay of its own (204), measured 2026-10-02.
    /// The context it followed is the session's `main_context`, which both name, or else the
    /// station's uri without `station:`, as librespot's `handle_transfer` takes it.
    private func continueAutoplay(of state: TransferState, positionMs: UInt64, paused: Bool) async throws {
        guard let spclient, let track = state.currentTrackUri else {
            throw LibrespotError.notInitialized
        }
        let contextUri = state.mainContextUri ?? Self.contextBeforeAutoplay(state.contextUri)
        let followsStation = contextUri != state.contextUri
        async let resolved: SPClient.ResolvedContext? = contextUri.isEmpty ? nil : try? await spclient.resolveContext(contextUri)

        let queued = state.playsQueuedTrack ? track : nil
        let first = state.currentRow ?? state.sessionUid.flatMap { state.contextTrackUids.firstIndex(of: $0) }

        var rows: [String]
        var uids: [String?]
        var stationUri = state.autoplayContextUri ?? (followsStation ? state.contextUri : nil)
        if let first, first < state.contextTrackUris.count {
            rows = Array(state.contextTrackUris[first...])
            uids = Array(state.contextTrackUids[first...])
        } else {
            let seed = state.contextTrackUris.suffix(PlaybackQueue.autoplaySeedLimit - 1) + [track]
            let station = try? await spclient.resolveAutoplay(contextUri: contextUri, recentTrackUris: Array(seed))
            let after = zip(station?.tracks ?? [], station?.uids ?? []).filter { $0.0 != track }
            let picked = (queued == nil ? [(track, state.currentTrackUid)] : []) + after
            rows = picked.map(\.0)
            uids = picked.map(\.1)
            stationUri = station?.uri ?? stationUri
        }

        let context = await resolved
        try await play(
            contextUri: contextUri,
            tracks: context?.tracks ?? [],
            uids: context?.uids ?? [],
            startIndex: max(0, (context?.tracks.count ?? 0) - 1),
            metadata: context?.metadata ?? [:],
            restrictions: context?.restrictions ?? .init(),
            playingQueued: queued,
            playingAutoplay: (rows, uids, stationUri),
            positionMs: positionMs,
            paused: paused,
        )
    }

    /// The context autoplay followed, as a handover names it: a station's uri without
    /// `station:`, as librespot's `handle_transfer` takes it, and any other uri as it is.
    nonisolated static func contextBeforeAutoplay(_ uri: String) -> String {
        uri.hasPrefix("spotify:station:") ? uri.replacingOccurrences(of: "station:", with: "") : uri
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
            // from track 4" stopped after track 4. Named with an index, the
            // track decides where, as librespot's `PlayingTrack` does.
            let positionMs = playCommand.positionMs ?? 0
            switch playCommand.context {
            case let .uri(uri):
                try? await play(
                    uriOrUrl: uri,
                    trackIndex: playCommand.index,
                    startingAtUri: playCommand.trackUri,
                    startingAtUid: playCommand.trackUid,
                    positionMs: positionMs,
                )
            case let .tracks(uris):
                try? await playTracks(
                    uris,
                    trackIndex: playCommand.index,
                    startingAtUri: playCommand.trackUri,
                    positionMs: positionMs,
                )
            }

        case .pause:
            await pause()

        case .resume:
            try? await resume()

        case let .seekTo(positionMs):
            try? await audioPipeline?.seek(positionMs: positionMs)

        case let .next(trackUri, uid):
            // A queue row clicked on another device names its track, and its uid where this
            // device reported one, which names the row. Without one the jump goes to the
            // track's first copy ahead, as librespot's `handle_next`. (go-librespot takes the
            // first row whose uid or uri matches, `ContextTrackComparator`.)
            if let trackUri {
                try? await skip(toNext: nil, uri: trackUri, uid: uid)
            } else {
                try? await advanceUserInitiated()
            }

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
                let track = repeatTrack ?? (playbackQueue.repeatMode == .track)
                let context = repeatContext ?? (playbackQueue.repeatMode == .context)
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

        case let .userAttributesMutated(names):
            if names.contains("autoplay") {
                setAutoplay(!autoplay)
            }

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
        queue: QueueState? = nil,
    ) {
        let state = PlaybackState(
            isPlaying: playing && !paused,
            isPaused: paused,
            trackUri: trackUri,
            positionMs: positionMs,
            durationMs: knownDurationMs,
            shuffle: playbackQueue.shuffleEnabled,
            repeatTrack: playbackQueue.repeatMode == .track,
            repeatContext: playbackQueue.repeatMode == .context,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            canShuffle: playbackQueue.restrictions.allowsShuffle,
        )
        let arrived = localState == nil
        localState = state
        positionCache.withLock { $0 = UInt64(max(0, positionMs)) }
        if arrived {
            lineUpAutoplay()
        }
        publish {
            $0.playback = state
            if let queue {
                $0.queue = queue
            }
        }
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
        // A load announced while this waited has published its own state.
        guard localState?.trackUri == current.trackUri else { return }
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
            streams: streams,
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
