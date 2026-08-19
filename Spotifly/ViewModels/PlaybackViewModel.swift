//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import Combine
import MediaPlayer
import QuartzCore
import SwiftUI

// MARK: - Playback View Model

@MainActor
@Observable
final class PlaybackViewModel {
    /// Shared singleton instance - ensures only one timer runs
    static let shared = PlaybackViewModel()

    /// Reference to AppStore for reading current track metadata (set by LoggedInView)
    private weak var store: AppStore?

    /// Reference to QueueService, used to resync after a remote start (set by LoggedInView).
    /// Remote playback produces no Rust callbacks, so nothing else would update the UI.
    private weak var queueService: QueueService?

    /// Set when a play request arrived with nowhere to serve it: no local player and no
    /// active remote device. The view presents the Auth / Cancel alert on this.
    var needsStreamingAuthorization = false

    var isPlaying = false
    var isLoading = false
    var currentTrackUri: String? {
        didSet {
            if oldValue != currentTrackUri {
                trackDurationMs = 0
                reconcileQueueCurrentTrack()
            }
        }
    }

    private var lastHandledTrackUri: String?
    var errorMessage: String?

    /// Returns the URI of the currently playing track (alias for currentTrackUri)
    var currentlyPlayingURI: String? {
        currentTrackUri
    }

    /// Length of the current track, as the stream reports it. Zero until one is known, which
    /// is what stops a previous track's length being applied to a new one — see
    /// `clampedToTrack`. The position that goes with it is derived from the anchor rather
    /// than stored alongside; see `currentPositionMs`.
    var trackDurationMs: UInt32 = 0

    /// Volume (0.0 - 1.0)
    var volume: Double = 0.5 {
        didSet {
            // Apply the output gain immediately (not debounced) so local volume
            // changes are audible at once instead of after the render buffer drains.
            SpotifyPlayer.setOutputVolume(volume)
            // Skip applying to Spirc if this change came from a remote volume callback
            guard !isSettingVolumeLocally else { return }
            // Debounce volume changes to avoid flooding Spirc with requests
            volumeSubject.send(volume)
            // Only persist when Spotifly is the active device; don't overwrite local volume
            // with a remote device's volume if the user is dragging the slider in Connect mode.
            if remoteVolume == nil {
                saveVolume()
            }
        }
    }

    /// Volume of the active remote Spotify Connect device (nil when Spotifly is active).
    /// The volume slider uses this for display when set.
    var remoteVolume: Double?

    var isShuffleEnabled = false

    /// Whether Swift knows that Rust has completed at least one usable initialization.
    /// This stays true through transient disconnects because Rust owns their recovery.
    private var isInitialized = false

    /// Whether this Mac can currently play audio itself.
    ///
    /// Cached credentials existing on disk is not the same fact: they can be revoked or
    /// stale, in which case initialization fails and the app must still offer to
    /// re-authorize. Anything asking "is this Mac a playback device" wants this, not the
    /// presence of a file.
    var isLocalPlaybackAvailable: Bool {
        isInitialized
    }

    /// Whether the local librespot session can currently provide advancing playback state.
    private var isConnectionReady = false
    private var lastAlbumArtURL: String?
    private var connectionStateSubscription: AnyCancellable?
    private var playbackStateSubscription: AnyCancellable?
    private var volumeSubscription: AnyCancellable?
    private var loadingSubscription: AnyCancellable?
    /// Flag to prevent feedback loop when we set volume locally
    private var isSettingVolumeLocally = false
    /// Subject for debouncing volume changes
    private let volumeSubject = PassthroughSubject<Double, Never>()
    /// Subscription for debounced volume operations
    private var volumeDebounceSubscription: AnyCancellable?
    /// Subject for debouncing seek requests
    private let seekSubject = PassthroughSubject<UInt32, Never>()
    /// Subscription for debounced seek operations
    private var seekSubscription: AnyCancellable?
    /// The in-flight initialization or restart, so concurrent callers coalesce onto one
    private var initializationTask: Task<Void, Never>?

    /// Bumped when a logout invalidates whatever the player lifecycle is doing. Mirrors
    /// Rust's session generation: cancellation is cooperative and the FFI calls do not
    /// observe it, so an initialization already inside `spotifly_init_player` has to be
    /// caught on the way out instead.
    private var lifecycleGeneration: UInt64 = 0

    /// True while a logout teardown is running. Suppresses the readiness adoption below: a
    /// snapshot published before Rust's flags catch up would otherwise mark the player
    /// initialized again, and the disconnected snapshots that follow deliberately do not
    /// clear that flag — so the next account would skip initialization entirely.
    private var isLoggingOut = false

    /// The logout teardown in flight, if any. Later callers await it rather than starting a
    /// second one — two would each reset `isLoggingOut` on their own way out, so the first
    /// to finish would reopen the door while the other was still tearing down.
    private var logoutTask: Task<Void, Never>?

    private init() {
        setupConnectionStateSubscription()
        setupPlaybackStateSubscription()
        setupVolumeSubscription()
        setupVolumeDebounceSubscription()
        setupLoadingSubscription()
        setupSeekSubscription()
        setupRemoteCommandCenter()

        // Load saved volume (but don't apply it yet - mixer isn't initialized)
        let savedVolume = UserDefaults.standard.double(forKey: "playbackVolume")
        if savedVolume > 0 {
            volume = savedVolume
        }
        // Volume will be applied when playback starts

        // Set initial Now Playing info to claim media controls
        var initialInfo: [String: Any] = [:]
        initialInfo[MPMediaItemPropertyTitle] = Self.unresolvedTrackTitle
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        // Start position update timer
        startPositionTimer()
    }

    /// Tears down and rebuilds the player even if it is already initialized.
    /// Used by the manual connection retry and by the wake fallback when Rust has no
    /// session to reconnect.
    func forceReinitialize() async {
        await runInitialization(force: true)
    }

    /// Initializes the player unless it is already up.
    func initializeIfNeeded() async {
        await runInitialization(force: false)
    }

    /// Tears the Rust session down on logout.
    ///
    /// Deliberately does not wait for an initialization that may be in flight. Waiting would
    /// hang the logout behind a stalled network setup, and it is not needed: `shutdown()`
    /// raises the teardown flag before it touches Spirc, and an initialization finishing
    /// afterwards sees that flag and clears what it built instead of publishing it.
    ///
    /// Ordering against a *replacement* session is the caller's job — it awaits this before
    /// clearing the auth state, so no login can start a rebuild until this has returned.
    func shutdownForLogout() async {
        // Invalidate an initialization in flight without waiting for it and without
        // cancelling it. Waiting would hang the logout behind a stalled network setup;
        // cancelling would be worse than useless, because `waitUntilReady` swallows it and
        // would then spin on the main actor until its timeout. The run is left in place so a
        // replacement login still serializes behind it — it just no longer owns the outcome,
        // and tears down whatever it built once it notices the generation moved.
        if let existing = logoutTask {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            lifecycleGeneration &+= 1
            isInitialized = false
            isLoggingOut = true
            defer { isLoggingOut = false }

            await SpotifyPlayer.shutdownAndCleanup()
        }
        logoutTask = task
        await task.value
        logoutTask = nil
    }

    /// Serializes every initialization and restart through one in-flight task.
    ///
    /// `@MainActor` stops two of these running *simultaneously*, but not from
    /// *overlapping*: every `await` is a suspension point where another caller can enter,
    /// and `SpotifyPlayer.initialize` performs a Rust cleanup followed by a rebuild. Two
    /// overlapping calls can therefore interleave one call's cleanup with the other's
    /// rebuild, which is how Swift ends up holding state belonging to a Rust generation
    /// that has already been replaced.
    ///
    /// Late callers await the in-flight run instead of starting a competing one. That also
    /// coalesces concurrent explicit rebuild requests, for which one rebuild is the correct
    /// response.
    private func runInitialization(force: Bool) async {
        // Nothing may build a player while one is being torn down. The view is still mounted
        // during a logout, so a playback action or a startup task can land here — and it
        // would capture the already-bumped lifecycle generation, so the stale-run check
        // would wave it through while `spotifly_init_player` clears the teardown flag,
        // re-announcing the account that just logged out.
        guard !isLoggingOut else { return }

        // Wait out whatever is in flight, then decide again. Coalescing onto it and
        // returning is right when it was a healthy initialization — but it may equally have
        // been a run for an account that has since logged out, and that one leaves the work
        // undone. `isInitialized` distinguishes the two.
        let generationBeforeWaiting = lifecycleGeneration
        var waitedForAnother = false
        while let existing = initializationTask {
            await existing.value
            if initializationTask == existing {
                initializationTask = nil
            }
            waitedForAnother = true
        }

        // A run we waited for that left a healthy player has already served this caller,
        // forced or not: what a forced rebuild asks for is a working session, and tearing
        // the fresh one down to build another would be pure destruction.
        if waitedForAnother, isInitialized {
            return
        }

        // A logout can land while this caller is suspended above. Its access token belongs
        // to the account that just left, so building with it would put that account straight
        // back on Spotify Connect — and the lifecycle check inside `performInitialization`
        // would not catch it, because by then the bumped generation is the current one.
        guard generationBeforeWaiting == lifecycleGeneration else { return }
        guard force || !isInitialized else { return }

        let task = Task { @MainActor in
            await performInitialization()
        }
        initializationTask = task
        await task.value
        // Only clear the slot while it is still ours: a logout drops the handle, and a
        // replacement login may already have installed its own by the time this resumes.
        if initializationTask == task {
            initializationTask = nil
        }
    }

    private func performInitialization() async {
        // We are about to tear down the Rust side, so nothing is initialized until the
        // rebuild proves otherwise. Matters when initialize() throws on a restart.
        isInitialized = false
        isLoading = true
        let generation = lifecycleGeneration
        do {
            try await SpotifyPlayer.initialize()

            // Readiness is the authoritative condition, not "initialize() returned". The
            // old code set isInitialized as soon as the FFI call came back and then polled
            // Spirc while ignoring the timeout, so Swift could permanently believe the
            // player was up while every Connect command failed — and initializeIfNeeded
            // would then refuse to try again. Leaving the flag false on timeout means the
            // next caller retries.
            if await waitUntilReady() {
                isInitialized = true
                errorMessage = nil
            } else {
                debugLog("PlaybackViewModel", "Player did not become ready within \(Self.readinessTimeout)")
                errorMessage = "Player did not become ready"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        // Checked on both paths on purpose. `spotifly_init_player` clears the teardown flags
        // on its way in, so an initialization that overlapped a logout can bring a session up
        // for an account that is gone — and it reports failure while doing so, because the
        // logout's cleanup superseded it. Rust cannot always clear that itself: it only knows
        // the attempt was superseded, not whether something newer legitimately owns the
        // globals. Swift does know, so it takes them down here.
        if generation != lifecycleGeneration {
            debugLog("PlaybackViewModel", "Initialization outlived a logout — tearing it back down")
            await SpotifyPlayer.shutdownAndCleanup()
            isInitialized = false
            errorMessage = nil
        }

        // Reset stale playback state — after (re)init Rust has no track/context loaded.
        // Publish the stopped rate before clearing the URI, then remove the old track's
        // metadata. Harmless on a first init, where these are already at their defaults.
        isPlaying = false
        updateNowPlayingPosition()
        currentTrackUri = nil
        lastHandledTrackUri = nil
        updateNowPlayingInfo()
        anchorPosition(0)
        isLoading = false
    }

    /// How long to wait for the player to become usable after initialization.
    private static let readinessTimeout: Duration = .seconds(5)

    /// Polls until Rust reports a usable player, or the timeout expires.
    ///
    /// Both halves are required: every Spotifly control goes through Spirc, so a connected
    /// session without a ready Spirc is not a player we can drive.
    private func waitUntilReady() async -> Bool {
        let deadline = ContinuousClock.now + Self.readinessTimeout
        while ContinuousClock.now < deadline {
            if SpotifyPlayer.isSessionConnected, SpotifyPlayer.isSpircReady {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return SpotifyPlayer.isSessionConnected && SpotifyPlayer.isSpircReady
    }

    /// Where a play request should go.
    enum PlaybackTarget: Equatable {
        case local
        case remote(deviceId: String)
        case needsAuthorization
    }

    /// Decides where to play.
    ///
    /// Local wins when it exists; otherwise an active remote device serves the request over
    /// the Web API. Only when neither exists is there anything to ask the user about —
    /// nagging about local streaming while a phone is playing would be noise.
    static func playbackTarget(isInitialized: Bool, activeDeviceId: String?) -> PlaybackTarget {
        if isInitialized {
            return .local
        }
        if let activeDeviceId {
            return .remote(deviceId: activeDeviceId)
        }
        return .needsAuthorization
    }

    func play(uriOrUrl: String, trackIndex: Int = -1) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        switch resolvedPlaybackTarget() {
        case .local:
            await startLocally(startedUri: uriOrUrl) {
                try await SpotifyPlayer.play(uriOrUrl: uriOrUrl, trackIndex: trackIndex)
            }

        case let .remote(deviceId):
            // One uri either way: the command's own context builder tells a track from a
            // context, where the Web API needed the caller to split them into two fields.
            await startRemotely(
                .play(uri: Self.remoteStartUri(for: uriOrUrl), trackIndex: trackIndex),
                deviceId: deviceId,
            )

        case .needsAuthorization:
            needsStreamingAuthorization = true
        }
    }

    func playTrack(trackId: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)")
    }

    func playTracks(_ trackUris: [String]) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        guard !trackUris.isEmpty else {
            errorMessage = "No tracks to play"
            return
        }

        switch resolvedPlaybackTarget() {
        case .local:
            await startLocally(startedUri: trackUris[0]) {
                try await SpotifyPlayer.playTracks(trackUris)
            }

        case let .remote(deviceId):
            await startRemotely(
                .play(trackUris: trackUris),
                deviceId: deviceId,
            )

        case .needsAuthorization:
            needsStreamingAuthorization = true
        }
    }

    /// Starts song radio, which only the local player can do.
    ///
    /// Radio is a Spirc feature with no Web API equivalent, so unlike `play` it cannot fall
    /// back to a remote device. Without a local player the command was previously issued
    /// anyway and its FFI error discarded, so track cards and context menus silently did
    /// nothing; asking for authorization is the honest answer.
    func playRadio(trackUri: String) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        guard isInitialized else {
            needsStreamingAuthorization = true
            return
        }

        SpotifyPlayer.playRadio(trackUri: trackUri)
    }

    /// The uri a remote play request should name.
    ///
    /// **One uri, not two fields.** The Web API needed a play request split into `context_uri`
    /// *or* `uris`, because sending a track as a context failed; connect-state takes one uri
    /// and `ConnectCommand.Context` decides how to carry it. What survives from that split is
    /// the normalization: `play(uriOrUrl:)` accepts an `open.spotify.com/track/ID` link as
    /// readily as a uri, and only the uri form can be played.
    static func remoteStartUri(for uriOrUrl: String) -> String {
        if let id = trackId(from: uriOrUrl) {
            return "spotify:track:\(id)"
        }
        return uriOrUrl
    }

    /// The track id in a Spotify track URI or link, if it is one.
    private static func trackId(from uriOrUrl: String) -> String? {
        if let range = uriOrUrl.range(of: "spotify:track:") {
            return String(uriOrUrl[range.upperBound...])
        }
        guard let range = uriOrUrl.range(of: "open.spotify.com/track/") else { return nil }
        let rest = uriOrUrl[range.upperBound...]
        let id = rest.prefix { $0 != "?" && $0 != "/" && $0 != "#" }
        return id.isEmpty ? nil : String(id)
    }

    /// Decides where to play.
    ///
    /// **There is no longer a device list to refresh before giving up.** This used to ask
    /// `/me/player/devices` when it was about to answer "nowhere", because the device table is
    /// pushed from the cluster and nothing pushes without a local session — so a phone that
    /// started playing after launch was invisible until something asked.
    ///
    /// The cluster is now the only source, and it needs the dealer socket librespot holds, so
    /// there is nothing left to ask. That narrows what this app can do for a user who declined
    /// to enable playback on this Mac: with no session there are no devices, so playing to a
    /// phone is no longer offered and `.needsAuthorization` is the honest answer. Enabling
    /// playback is also the fix, which is what the alert already says.
    private func resolvedPlaybackTarget() -> PlaybackTarget {
        Self.playbackTarget(
            isInitialized: isInitialized,
            activeDeviceId: store?.activeDeviceId,
        )
    }

    /// Runs a local Spirc start and folds its outcome into `isLoading` / `errorMessage`.
    ///
    /// `play` and `playTracks` differ only in the call they make and in which uri counts as
    /// the one that started, so the state-keeping around it is written once. The remote
    /// half is `startRemotely` below.
    private func startLocally(
        startedUri: String,
        _ start: @MainActor () async throws -> Void,
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            try await start()
            handlePlaybackStarted(trackId: startedUri)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Starts content on a remote device and then resyncs, because nothing else will.
    ///
    /// With no Spirc session there are no playback or queue callbacks — a successful start
    /// would otherwise leave the now-playing bar showing whatever it showed before.
    private func startRemotely(
        _ command: ConnectCommand,
        deviceId: String,
    ) async {
        guard let from = store?.connection?.deviceId, !from.isEmpty else {
            errorMessage = String(localized: "error.no_playback_device")
            return
        }

        isLoading = true
        errorMessage = nil

        // Captured before any awaiting: a logout can land during the request or the settle
        // delay, and a superseded run must not write (see AGENTS.md).
        let revisionAtStart = store?.liveStateRevision

        do {
            try await SpclientAPI().sendCommand(command, from: from, to: deviceId)

            // Let Spotify settle before asking what it thinks is playing.
            try? await Task.sleep(for: .milliseconds(600))

            if let queueService, store?.liveStateRevision == revisionAtStart {
                _ = await queueService.fetchInitialPlaybackState()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addToQueue(uri: String) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        errorMessage = nil

        // Use Spirc to add to queue directly via librespot
        SpotifyPlayer.addToQueue(uri: uri)
        // Queue update will come via Mercury callback
    }

    // MARK: - Playback State Helpers

    /// Common setup after playback has started
    private func handlePlaybackStarted(trackId: String) {
        currentTrackUri = trackId
        lastHandledTrackUri = trackId
        isPlaying = true
        // Apply volume after playback starts (mixer is now initialized)
        SpotifyPlayer.setVolume(volume)
        updateNowPlayingInfo()
        syncPositionAnchor()
        // Note: favorite status is checked by NowPlayingBarView's .task(id:) when currentTrackUri changes
    }

    func togglePlayPause(trackId: String) async {
        if isPlaying, currentTrackUri == trackId {
            // Route through pause() rather than calling the FFI directly: it carries the
            // connectivity guard and the Web API fallback for remote devices, and it
            // leaves isPlaying to the Mercury callback instead of asserting it here
            pause()
        } else if !isPlaying, currentTrackUri == trackId {
            resume()
        } else {
            // Play new track
            await playTrack(trackId: trackId)
        }
    }

    /// Stops playback and clears the view model's playback state. Called on logout.
    ///
    /// Deliberately not gated on the session being connected, unlike the transport commands.
    /// Those go through Spirc, which rejects them without a session, so acting on them
    /// locally would desync the UI. `spotifly_stop` instead stops the Player directly — a
    /// local teardown, not a Connect command — and works while disconnected. Guarding it
    /// meant logging out during an outage left buffered audio playing and the previous track
    /// showing.
    func stop() {
        SpotifyPlayer.stop()
        isPlaying = false
        currentTrackUri = nil
        lastHandledTrackUri = nil
        updateNowPlayingInfo()
    }

    /// Sets the AppStore reference. Call this after AppStore is created.
    func setStore(_ store: AppStore) {
        self.store = store
        reconcileQueueCurrentTrack()
    }

    /// Sets the QueueService used to resync after a remote start.
    func setQueueService(_ queueService: QueueService) {
        self.queueService = queueService
    }

    /// The logical playback URI is authoritative for the queue's current pointer. Track
    /// transitions do not emit a SetQueue event, so this runs at the URI change itself.
    private func reconcileQueueCurrentTrack() {
        guard let currentTrackUri,
              let trackId = SpotifyAPI.parseTrackURI(currentTrackUri),
              store?.reconcileQueueCurrentTrack(with: trackId) == true
        else { return }

        debugLog("PlaybackViewModel", "Reconciled queue current pointer to \(trackId)")
    }

    // MARK: - Playback Control (via Spirc or connect-state)

    /// Issues a transport command locally when Spotifly is the active device, and through
    /// connect-state otherwise. Returns whether the command was issued at all.
    ///
    /// The local branch is gated on the session being connected: during a reconnect Rust
    /// rejects commands, and the callers that move the UI optimistically must not do so for
    /// a command that never happened — hence the `Bool` rather than a plain dispatch.
    /// The remote branch reports failures through `errorMessage`; the local branch leaves
    /// the resulting playback state to the Mercury callback.
    ///
    /// `isActiveDevice` is two-valued and the cluster is not: Spotifly is active, another
    /// device is, or **nobody** is. The third state is reached routinely — waking from sleep
    /// gets there, because the sleep teardown shuts Spirc down and librespot's
    /// `SessionDisconnected` handler clears the active flag.
    ///
    /// **That state used to be found out by asking**: the Web API answered 404 and the 404 was
    /// caught. connect-state addresses the target in the *url*, so with nobody active there is
    /// no url to build — the same condition, now a precondition instead of a round trip, and
    /// one fewer request on a path the user is waiting on.
    ///
    /// What the local fallback recovers is **resume**, which is also the only one that needs
    /// recovering. `spotifly_resume` activates and reloads the saved context, so playback
    /// comes back where it stopped. The others reach an inactive Spirc, which drops them —
    /// and that is the right outcome rather than a gap to close: with nobody active there is
    /// no context loaded and no track playing, so there is nothing to pause, skip or seek.
    /// Activating for them would take the Connect role away from the user's other clients in
    /// order to accomplish nothing, and making them work would mean silently starting
    /// playback in response to "next" or "seek" — a different feature, not this fix.
    @discardableResult
    private func sendTransportCommand(
        _ name: String,
        local: @escaping () -> Void,
        remote: @escaping (_ from: String, _ to: String) async throws -> Void,
        declined: @escaping (SpclientError) -> Void = { _ in },
    ) -> Bool {
        guard SpotifyPlayer.isActiveDevice else {
            guard let route = connectRoute() else {
                // Nothing out there to command, so command ourselves. Rust takes the
                // Connect role on the way through — `spotifly_resume` reloads the saved
                // context and activates — which is what pressing a transport control
                // with no device active asks for.
                guard SpotifyPlayer.isSessionConnected else {
                    debugLog("PlaybackViewModel", "\(name) dropped - no active device and session not connected")
                    return false
                }
                debugLog("PlaybackViewModel", "\(name) had no active device - running locally")
                local()
                return true
            }

            Task {
                do {
                    try await remote(route.from, route.to)
                } catch let error as SpclientError where error.isDeclined {
                    // Spotify refusing on its own terms — no track to go back to, or a device
                    // that will not take the command. The user pressed a control deliberately
                    // and nothing is broken, so this is a log line rather than an error banner.
                    debugLog("PlaybackViewModel", "\(name) declined: \(error.localizedDescription)")
                    declined(error)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return true
        }

        // During reconnection, session may not be fully connected yet
        guard SpotifyPlayer.isSessionConnected else {
            debugLog("PlaybackViewModel", "\(name) ignored - session not connected yet")
            return false
        }
        local()
        return true
    }

    /// Who to address a connect-state command as, and to. Nil when nothing is active.
    ///
    /// `from` is our own device id. The backend does not validate that segment — it derives the
    /// source from the session, which is why librespot's transfer passes its own id for both
    /// sides — so this is an identifier for their logs rather than a routing decision.
    private func connectRoute() -> (from: String, to: String)? {
        guard let store,
              let to = store.activeDeviceId, !to.isEmpty,
              let from = store.connection?.deviceId, !from.isEmpty
        else { return nil }

        return (from, to)
    }

    func next() {
        guard sendTransportCommand(
            "next()",
            local: { SpotifyPlayer.next() },
            remote: { try await SpclientAPI().sendCommand(.next, from: $0, to: $1) },
        ) else {
            return
        }

        // Immediately reset position to 0 for responsive UI
        anchorPosition(0, optimistic: true)
        updateNowPlayingInfo()
    }

    /// Previous track, or the start of this one.
    ///
    /// `hasPrevious` enables the control once playback is more than three seconds in even with
    /// no earlier track, because restarting is what pressing it then means — and the local
    /// player does exactly that. A remote device does not: `skip_prev` comes back
    /// `403 no_prev_track`, which left the button enabled and doing nothing while an error
    /// banner blamed Spotify. So the refusal is answered with the seek it stood for.
    func previous() {
        guard sendTransportCommand(
            "previous()",
            local: { SpotifyPlayer.previous() },
            remote: { try await SpclientAPI().sendCommand(.previous, from: $0, to: $1) },
            declined: { [weak self] error in
                guard error.isNoPreviousTrack else { return }
                self?.seek(to: 0)
            },
        ) else {
            return
        }

        // Immediately reset position to 0 for responsive UI
        anchorPosition(0, optimistic: true)
        updateNowPlayingInfo()
    }

    func seek(to positionMs: UInt32) {
        // Update anchor immediately for smooth UI feedback during scrubbing
        anchorPosition(positionMs, optimistic: true)
        updateNowPlayingPosition()

        // Debounce the actual seek operation to avoid flooding Spirc/API with requests
        seekSubject.send(positionMs)
    }

    func pause() {
        // State update will come from Mercury callback
        sendTransportCommand(
            "pause()",
            local: { SpotifyPlayer.pause() },
            remote: { try await SpclientAPI().sendCommand(.pause, from: $0, to: $1) },
        )
    }

    func resume() {
        guard sendTransportCommand(
            "resume()",
            local: { SpotifyPlayer.resume() },
            remote: { try await SpclientAPI().sendCommand(.resume, from: $0, to: $1) },
        ) else {
            return
        }

        // Don't call syncPositionAnchor() - Rust returns 0 immediately after resume.
        // The position we already hold is correct from the paused state: only the clock
        // restarts.
        restartPositionClock()
        updateNowPlayingPosition()
    }

    func toggleShuffle() {
        let targetShuffle = !isShuffleEnabled

        sendTransportCommand(
            "toggleShuffle()",
            local: { SpotifyPlayer.setShuffle(targetShuffle) },
            remote: { try await SpclientAPI().sendCommand(.shuffle(targetShuffle), from: $0, to: $1) },
        )
    }

    /// Returns true if there are tracks in the queue after the current track
    var hasNext: Bool {
        guard let store else { return false }
        return !store.queue.nextTracks.isEmpty
    }

    /// Returns true if there are tracks before the current track or if we're past the start of the track
    var hasPrevious: Bool {
        guard let store else { return false }
        // Allow previous if we have previous tracks or if we're more than 3 seconds into the current track
        return !store.queue.previousTracks.isEmpty || currentPositionMs > 3000
    }

    // MARK: - Media Keys & Now Playing

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any existing handlers to prevent duplicates
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        // Play command
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying {
                    self.resume()
                }
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    self.pause()
                }
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    self.pause()
                } else {
                    self.resume()
                }
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            next()
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            previous()
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return }
                let positionMs = UInt32(seekEvent.positionTime * 1000)
                self.seek(to: positionMs)
            }
            return .success
        }
    }

    /// Title published while no logical track resolves.
    ///
    /// The app claims the media controls at init by publishing a Now Playing entry, and
    /// that claim is only as good as the entry: removing the title outright leaves a
    /// nameless row in Control Center. Falling back to the app name keeps the claim
    /// intact between tracks, after logout, and while metadata is still loading.
    private static let unresolvedTrackTitle = "Spotifly"

    /// The store entry for the *logical* track, which owns the displayed metadata.
    /// The decoded audio item may be a relinked alternative with a different ID.
    private var currentNowPlayingTrack: Track? {
        guard let currentTrackUri,
              let trackId = SpotifyAPI.parseTrackURI(currentTrackUri)
        else { return nil }
        return store?.tracks[trackId]
    }

    /// The duration to publish, or nil while none is known.
    ///
    /// The stream duration is authoritative but arrives after the URI does, and the URI
    /// `didSet` clears it on every track change. The store's duration bridges that gap,
    /// so the scrubber shows a length instead of --:-- for the first few frames.
    private var effectiveNowPlayingDurationMs: UInt32? {
        if trackDurationMs > 0 {
            return trackDurationMs
        }
        guard let storedDuration = currentNowPlayingTrack?.durationMs,
              storedDuration > 0
        else { return nil }
        return UInt32(storedDuration)
    }

    /// Writes duration, elapsed time, and playback rate into `info`.
    ///
    /// Duration and elapsed time move together: an elapsed time standing next to the
    /// *previous* track's duration is worse than no timing at all, so an unknown
    /// duration removes both keys rather than leaving one behind.
    private func applyNowPlayingTiming(to info: inout [String: Any]) {
        if let durationMs = effectiveNowPlayingDurationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
            let validPosition = min(currentPositionMs, durationMs)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }

    /// Full Now Playing update — sets track metadata, duration, position, rate, and artwork.
    /// Call on: track start, next/prev, initial Web API load.
    func updateNowPlayingInfo() {
        let currentTrack = currentNowPlayingTrack

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let currentTrack {
            nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrack.name
            nowPlayingInfo[MPMediaItemPropertyArtist] = currentTrack.artistName
        } else {
            nowPlayingInfo[MPMediaItemPropertyTitle] = Self.unresolvedTrackTitle
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
            // Drop the cover unconditionally rather than leaving it to the URL
            // comparison below. `lastAlbumArtURL` is not a reliable witness for what is
            // installed: a failed download clears it without uninstalling artwork that an
            // earlier, overlapping download for the same URL may have published. When the
            // two disagree here nothing else would ever clear the cover, and it would sit
            // beside the placeholder title indefinitely.
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
            lastAlbumArtURL = nil
        }

        applyNowPlayingTiming(to: &nowPlayingInfo)

        // Artwork arrives late — it has to be downloaded — so a changed cover is dropped
        // from the entry we publish now and reinstated by the download below. A missing
        // URL counts as a change: it drops the previous track's cover and downloads none.
        let artworkURL = currentTrack?.images.mediumURL
        let artworkChanged = artworkURL?.absoluteString != lastAlbumArtURL
        if artworkChanged {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        guard artworkChanged else { return }
        lastAlbumArtURL = artworkURL?.absoluteString
        if let artworkURL {
            downloadAlbumArt(from: artworkURL)
        }
    }

    /// Downloads `url` and publishes it as the Now Playing artwork.
    private func downloadAlbumArt(from url: URL) {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else { return }

                // Update Now Playing on main actor
                await MainActor.run {
                    // The track may have moved on while this was downloading; publishing
                    // now would put the old cover next to the new title.
                    guard self.currentNowPlayingTrack?.images.mediumURL == url else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    // Mark closure as @Sendable to fix crash - MPNowPlayingInfoCenter executes
                    // the closure on an internal dispatch queue, not on MainActor
                    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
                        image
                    }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            } catch {
                // Forget the URL so the next update retries instead of treating the
                // failed download as the cover already on screen.
                if self.lastAlbumArtURL == url.absoluteString {
                    self.lastAlbumArtURL = nil
                }
            }
        }
    }

    /// Lightweight Now Playing update — writes elapsed time, duration, and playback rate.
    /// No title, artist, or artwork processing. Call on: seek, play/pause, drift correction.
    ///
    /// Duration belongs here even though it is metadata: the URI `didSet` clears the stream
    /// duration on every track change, so a path that only wrote elapsed time would leave
    /// the previous track's duration standing against the new track's position.
    func updateNowPlayingPosition() {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        applyNowPlayingTiming(to: &nowPlayingInfo)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Player State Subscriptions

    /// Adopts a successful Rust-owned recovery after an explicit Swift initialization failed.
    ///
    /// Do not clear `isInitialized` on a not-ready snapshot: a transient disconnect is owned
    /// by Rust, and doing so would make the next user command start a destructive Swift
    /// rebuild. An explicit initialization clears it itself before rebuilding.
    private func setupConnectionStateSubscription() {
        connectionStateSubscription = SpotifyPlayer.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                syncConnectionReadiness()

                guard isConnectionReady,
                      !isInitialized,
                      !isLoggingOut,
                      initializationTask == nil
                else {
                    return
                }

                debugLog("PlaybackViewModel", "Adopting successful Rust-owned recovery")
                isInitialized = true
                errorMessage = nil
            }
    }

    /// Brings `isConnectionReady` in line with Rust, freezing the position when it drops.
    ///
    /// Reads the live flags rather than trusting the delivered snapshot, which may already
    /// be stale by the time it arrives.
    ///
    /// Called from the connection-state callback *and* once a second from the drift check.
    /// The second caller is deliberate: display interpolation now depends on this flag, so
    /// a single missed callback would leave the progress bar stopped during healthy
    /// playback — a more visible failure than the drift this prevents. Re-reading the flags
    /// on the timer makes that self-heal within a second, and routing both callers through
    /// here means the timer can never flip the flag without also freezing the position.
    private func syncConnectionReadiness() {
        let isReady = SpotifyPlayer.isSessionConnected && SpotifyPlayer.isSpircReady
        guard isReady != isConnectionReady else { return }

        if !isReady {
            freezePositionForDisconnect()
        }
        isConnectionReady = isReady
    }

    /// Pins the displayed position where playback actually stopped.
    ///
    /// Which value is truthful depends on who was playing:
    ///
    /// - **Local playback**: Rust's last Player event. It stopped advancing when the Player
    ///   did, so it is exactly where the audio ended.
    /// - **Remote playback**: the displayed position. Rust's Player position belongs to a
    ///   local Player that was not the one playing, so it is unrelated.
    ///
    /// The `rustPosition > 0` clause guards the gap between the two: Rust reports 0 both for
    /// "at the start" and for "nothing loaded". Snapping a running progress bar to zero
    /// because the position was cleared out from under it would be worse than holding the
    /// last shown value — so a zero is only adopted when we have no anchor of our own either.
    ///
    /// A teardown no longer produces such a zero: `PlayerEvent::Stopped` keeps the position
    /// now, because the resume path seeks to it. The clause still earns its place for the
    /// zeroes that remain — `EndOfTrack`, and the reset on logout.
    private func freezePositionForDisconnect() {
        let displayedPosition = interpolatedPositionMs
        let rustPosition = SpotifyPlayer.positionMs
        let frozenPosition = if SpotifyPlayer.isActiveDevice,
                                rustPosition > 0 || positionAnchorMs == 0
        {
            rustPosition
        } else {
            displayedPosition
        }

        anchorPosition(frozenPosition)
        debugLog("PlaybackViewModel", "Connection not ready, position frozen at \(frozenPosition)ms")
    }

    /// Subscribe to playback state updates from Mercury/Spirc
    /// This allows external control (e.g., pause from phone) to be reflected in the app
    private func setupPlaybackStateSubscription() {
        playbackStateSubscription = SpotifyPlayer.playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handlePlaybackStateUpdate(state)
            }
    }

    /// Subscribe to remote volume changes from Spirc
    /// This allows volume changes from other devices to update the local slider
    private func setupVolumeSubscription() {
        volumeSubscription = SpotifyPlayer.volumeChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volumeU16 in
                guard let self else { return }
                // Convert from 0-65535 to 0.0-1.0
                let normalizedVolume = Double(volumeU16) / 65535.0
                debugLog("PlaybackViewModel", "Remote volume change: \(volumeU16) -> \(normalizedVolume)")
                // Set flag to prevent feedback loop
                isSettingVolumeLocally = true
                volume = normalizedVolume
                isSettingVolumeLocally = false
                // Only persist when Spotifly is the active device
                if remoteVolume == nil {
                    saveVolume()
                }
            }
    }

    /// Subscribe to loading notifications from Spirc
    /// This fires early (~180ms) when a track starts loading, before metadata is fetched
    /// Allows faster Now Playing updates when playing from remote devices
    private func setupLoadingSubscription() {
        loadingSubscription = SpotifyPlayer.loading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                debugLog("PlaybackViewModel", "Loading notification: \(notification.trackUri) at \(notification.positionMs)ms")

                // Update current track URI immediately for faster Now Playing updates
                let trackChanged = !notification.trackUri.isEmpty && notification.trackUri != currentTrackUri
                if trackChanged {
                    currentTrackUri = notification.trackUri
                    // Mark as playing since we're loading a new track
                    isPlaying = true
                }

                // Use position from loading callback - this is reliable
                anchorPosition(notification.positionMs)

                if trackChanged {
                    updateNowPlayingInfo()
                }
            }
    }

    /// Subscribe to debounced seek requests
    /// Debounces rapid seek events (e.g., slider scrubbing) to avoid flooding Spirc with requests
    private func setupSeekSubscription() {
        seekSubscription = seekSubject
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] positionMs in
                self?.performSeek(to: positionMs)
            }
    }

    /// Perform the actual seek operation (called after debouncing)
    private func performSeek(to positionMs: UInt32) {
        let issued = sendTransportCommand(
            "performSeek",
            local: { SpotifyPlayer.seek(positionMs: positionMs) },
            remote: { try await SpclientAPI().sendCommand(.seek(toMs: Int(positionMs)), from: $0, to: $1) },
        )

        // seek(to:) already moved the anchor so scrubbing feels immediate. If Rust rejected
        // the command, re-sync from the real position instead of leaving the UI parked at a
        // position playback never reached.
        if !issued {
            syncPositionAnchor()
        }
    }

    /// Handle playback state update from Spirc callback
    private func handlePlaybackStateUpdate(_ state: PlaybackState?) {
        guard let state else { return }

        debugLog(
            "PlaybackViewModel",
            "Playback state update: playing=\(state.isPlaying), paused=\(state.isPaused), position=\(state.positionMs)ms, duration=\(state.durationMs)ms, shuffle=\(state.shuffle), uri=\(state.trackUri)",
        )

        // Authoritative state from Rust — let any in-flight Web API bootstrap know it is
        // now stale (see AppStore.liveStateRevision)
        store?.noteLiveStateReceived()

        // Update playing state
        // When active device: use SpotifyPlayer.isPlaying (local Spirc state)
        // When not active: use cluster state (remote device's actual state)
        let wasPlaying = isPlaying
        let newIsPlaying: Bool = if SpotifyPlayer.isActiveDevice {
            SpotifyPlayer.isPlaying
        } else {
            // Remote device: use cluster state - playing means actively playing (not paused)
            state.isPlaying && !state.isPaused
        }
        isPlaying = newIsPlaying

        // Update track if changed
        let trackChanged = !state.trackUri.isEmpty && state.trackUri != lastHandledTrackUri
        if trackChanged {
            lastHandledTrackUri = state.trackUri
        }

        if !state.trackUri.isEmpty, state.trackUri != currentTrackUri {
            currentTrackUri = state.trackUri
            // Note: Track metadata (name, artist, etc.) will be updated from queue
        }

        let hadStreamDuration = trackDurationMs > 0

        // Update duration. Values cross an FFI boundary as signed 64-bit integers, so do
        // not let malformed Connect state turn a narrowing conversion into a process trap.
        if let durationMs = Self.playbackMilliseconds(state.durationMs), durationMs > 0 {
            trackDurationMs = durationMs
        }
        let receivedFirstStreamDuration = !hadStreamDuration && trackDurationMs > 0

        isShuffleEnabled = state.shuffle

        // Sync position anchor on state changes. When monitoring a remote device,
        // position_ms is the position at timestamp_ms, which can be minutes old.
        if let posMs = Self.playbackMilliseconds(state.positionMs) {
            let anchor = positionAnchor(forPosition: state.positionMs, takenAt: state.timestampMs)
            debugLog("PlaybackViewModel", "Position anchor: \(positionAnchorMs) -> \(posMs)\(anchor.logSuffix)")
            anchorPosition(posMs, at: anchor.time)
        } else {
            debugLog("PlaybackViewModel", "Ignoring out-of-range playback position: \(state.positionMs)ms")
        }

        // Update Now Playing position if playback rate changed, or if track changed
        if trackChanged || receivedFirstStreamDuration {
            updateNowPlayingInfo()
        } else if wasPlaying != isPlaying {
            updateNowPlayingPosition()
        }
    }

    // MARK: - Position Tracking

    /// Narrows milliseconds from a Connect snapshot without trapping on malformed state.
    ///
    /// Positions and durations enter Swift as `Int64`, while the player and UI use
    /// `UInt32`. Spotify has produced a remote snapshot whose position was the current Unix
    /// time in milliseconds; a direct `UInt32` conversion traps on that value. Keeping the
    /// conversion exact lets the caller ignore a bad measurement and preserve its last
    /// usable anchor.
    nonisolated static func playbackMilliseconds(_ milliseconds: Int64) -> UInt32? {
        UInt32(exactly: milliseconds)
    }

    // Anchor-based position tracking using CACurrentMediaTime for precision
    // UI reads interpolatedPositionMs (computed), not currentPositionMs directly
    private var positionAnchorMs: UInt32 = 0
    private var positionAnchorTime: Double = CACurrentMediaTime()
    private var driftCorrectionTask: Task<Void, Never>?

    /// How far the display may disagree with Rust before the disagreement means something.
    private static let positionDisagreementMs: Int64 = 500

    /// How long an optimistic anchor is given to be confirmed before it is treated as a
    /// command that never happened. Long enough to cover the 150 ms seek debounce and the
    /// round trip after it — measured at ~25 ms from `spotifly_seek` to the state callback
    /// — and it restarts on each drag update, so a long scrub extends it rather than
    /// outliving it.
    private static let optimisticAnchorGrace: Double = 1.0

    /// When the anchor was last written by a transport command rather than by a
    /// measurement, and so is a promise about where playback is *going*. Cleared by the
    /// next authoritative anchor, which is what "the command landed" looks like from here.
    private var optimisticAnchorTime: Double?

    /// Re-anchors the displayed position: `positionMs` is where playback is, `time` is the
    /// moment it was there.
    ///
    /// The pair is one fact, and writing it in one place is the point: eleven call sites
    /// used to assign it field by field, and had already drifted apart over whether the
    /// position was capped at the track length.
    ///
    /// `time` defaults to now. A caller holding a snapshot that was true *earlier* — a
    /// Mercury or Web API state carrying a timestamp — passes that moment instead, so
    /// interpolation accounts for the delay rather than restarting the clock.
    ///
    /// `optimistic` marks the anchors that transport commands write ahead of playback, to
    /// keep scrubbing and skipping responsive. Those are promises rather than
    /// measurements, and `checkDriftAndSync` has to know the difference — so every other
    /// caller, all of which anchor something measured, clears the mark by writing.
    private func anchorPosition(
        _ positionMs: UInt32,
        at time: Double = CACurrentMediaTime(),
        optimistic: Bool = false,
    ) {
        positionAnchorMs = positionMs
        positionAnchorTime = time
        optimisticAnchorTime = optimistic ? CACurrentMediaTime() : nil
    }

    /// Restarts interpolation at the position already held, without claiming to have
    /// measured it.
    ///
    /// Resume is the only caller: it moves neither the position nor its truth, just the
    /// clock. Going through `anchorPosition` instead would re-assign the position to
    /// itself and, worse, clear the optimistic mark — telling `checkDriftAndSync` that a
    /// seek made while paused had been confirmed, when resuming confirms nothing.
    private func restartPositionClock() {
        positionAnchorTime = CACurrentMediaTime()
    }

    /// The position to report while playback is not advancing.
    ///
    /// Derived rather than stored. This used to be a third field assigned beside the anchor
    /// on every update, always to exactly this expression — a cache of a one-line derivation,
    /// whose only possible disagreement with its source was being stale. Reading it live also
    /// means a duration arriving after the position now caps it, where the stored copy kept
    /// whatever it was written with.
    var currentPositionMs: UInt32 {
        clampedToTrack(positionAnchorMs)
    }

    /// Computed position using anchor interpolation - UI should bind to this
    /// Called by TimelineView on every frame for smooth updates
    var interpolatedPositionMs: UInt32 {
        guard isPlaying, isConnectionReady else { return currentPositionMs }
        let elapsed = CACurrentMediaTime() - positionAnchorTime
        let elapsedMs = UInt32(max(0, min(elapsed * 1000, Double(UInt32.max - 1))))
        return clampedToTrack(positionAnchorMs.addingReportingOverflow(elapsedMs).partialValue)
    }

    /// Where to start the anchor clock for a snapshot, and what to say about it in the log.
    private struct PositionAnchor {
        let time: Double
        /// Trails the caller's own log line, which names the source. Empty when the snapshot
        /// carried no timestamp and there was nothing to compensate for.
        let logSuffix: String
    }

    /// Works out the anchor time for a position that was true at `timestampMs`.
    ///
    /// A snapshot carries a position and the moment it was measured, so the anchor is
    /// back-dated by the time since — otherwise interpolation reports a stale position as
    /// the current one. That is the ordinary case, and it is what keeps the progress bar in
    /// step with a remote device that Spotify last reported on some seconds ago.
    ///
    /// The compensation is **discarded** when it would carry the position past the end of
    /// the track. A snapshot that stale cannot describe what is playing now, and back-dating
    /// by it parks the bar at the track end, where it reads as broken rather than as behind.
    /// Anchoring at the raw position instead shows something genuinely measured, merely out
    /// of date, and the next update corrects it. Clamping the compensation to land exactly
    /// on the track end was considered and rejected: `clampedToTrack` already bounds the
    /// display, so it looks identical to no guard at all — it tidies the arithmetic without
    /// changing what the user sees.
    ///
    /// The bound reads `trackDurationMs` rather than taking a duration, so it is by
    /// construction the same length the display clamps against; both callers refresh it from
    /// the same snapshot before anchoring. This guard used to live only on the Web API path,
    /// but staleness is a property of Spotify's timestamp, not of the endpoint that carried
    /// it — cluster updates forward `player_state.timestamp` unchanged and can be minutes
    /// old, while local callbacks stamp the current time and compensate by nothing.
    private func positionAnchor(forPosition positionMs: Int64, takenAt timestampMs: Int64) -> PositionAnchor {
        let now = CACurrentMediaTime()
        guard timestampMs > 0 else { return PositionAnchor(time: now, logSuffix: "") }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsedMs = max(0, nowMs - timestampMs)
        let overshootsTrack = trackDurationMs > 0
            && positionMs + elapsedMs > Int64(trackDurationMs)

        guard !overshootsTrack else {
            return PositionAnchor(
                time: now,
                logSuffix: " (timestamp was \(elapsedMs)ms ago, stale — ignoring compensation)",
            )
        }

        return PositionAnchor(
            time: now - Double(elapsedMs) / 1000.0,
            logSuffix: " (timestamp was \(elapsedMs)ms ago)",
        )
    }

    /// Caps a position at the track length, leaving it untouched while no length is known.
    ///
    /// The unknown case is what makes a track change safe: the `currentTrackUri` `didSet`
    /// clears the duration before the new track's position arrives, so the previous track's
    /// length is never applied to it.
    private func clampedToTrack(_ positionMs: UInt32) -> UInt32 {
        trackDurationMs > 0 ? min(positionMs, trackDurationMs) : positionMs
    }

    /// Runs the drift check once a second for the lifetime of the view model.
    ///
    /// Once a second, not every frame: the UI interpolates its own position through
    /// `TimelineView`, so this exists only to pull that clock back to Rust's reality.
    private func startPositionTimer() {
        driftCorrectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                checkDriftAndSync()
            }
        }
    }

    /// Sync position anchor with Rust - call after seek, play, resume, track change
    private func syncPositionAnchor() {
        let rustPosition = SpotifyPlayer.positionMs
        // Don't overwrite valid position with 0 - Rust may not have position ready yet
        if rustPosition == 0, positionAnchorMs > 0 {
            debugLog("PlaybackViewModel", "syncPositionAnchor: skipping - rustPosition=0 but have valid anchor=\(positionAnchorMs)")
            return
        }
        debugLog("PlaybackViewModel", "syncPositionAnchor: rustPosition=\(rustPosition), was positionAnchorMs=\(positionAnchorMs)")
        anchorPosition(rustPosition)
    }

    /// Called every second to check for drift and sync state
    private func checkDriftAndSync() {
        var didCorrectDrift = false

        defer {
            if didCorrectDrift {
                updateNowPlayingPosition()
            }
        }

        // Readiness gates interpolation, so recover here from a callback that never arrived
        // rather than leaving the progress bar stopped until the next one does.
        syncConnectionReadiness()

        // Sync playing state with Rust - only when we're the active device
        // When monitoring remote playback, state comes from cluster updates
        if SpotifyPlayer.isActiveDevice {
            let rustIsPlaying = SpotifyPlayer.isPlaying
            if rustIsPlaying != isPlaying {
                isPlaying = rustIsPlaying
                syncPositionAnchor()
                didCorrectDrift = true
            }
        }

        // A held position is honest while disconnected: Rust has no advancing Player state
        // to anchor interpolation to, and will rehydrate from its last raw position.
        guard isPlaying, isConnectionReady else { return }

        // Check for significant drift from Rust position - only when active device
        // Remote playback position is interpolated from cluster timestamp, not real-time.
        // Compare even when the Rust value did not change: a frozen value is precisely the
        // signal that must pull a still-running Swift clock back to reality.
        //
        // The two directions are not the same measurement, so they do not share a
        // threshold. Rust reports where the *decoder* is, and the decoder runs ahead of
        // what is audible by whatever `AudioRenderer` still holds buffered — normally
        // around `maxBufferAheadSeconds`, though that is a pacing target enforced by
        // sleeping after a write rather than a ceiling, and re-arming the throttle on a
        // route change can bank more.
        //
        // - **Display ahead of Rust** cannot come from buffering, since the decoder is
        //   always in front. It means the Player stopped producing while our clock kept
        //   running, which is the stall this check exists for. Half a second is plenty.
        // - **Display behind Rust** is normally just that buffer, and correcting to it
        //   would jump the bar forward into audio nobody has heard yet — the fight with
        //   the Spirc position that made the bar jitter through a context's first track.
        //
        // The exception in both directions is an anchor a transport command wrote ahead of
        // playback. That is a promise, not a measurement, and the two disagree by design
        // until the command lands — so nothing can be judged inside the grace window. Past
        // it, an optimistic anchor that no measurement has confirmed is one Rust never
        // carried out: `performSeek` rolls back a command it could not *issue*, but one
        // that was issued and then rejected reports nothing back, since
        // `SpotifyPlayer.seek` discards the FFI result. Then either direction is evidence,
        // because the display is somewhere playback never went.
        if SpotifyPlayer.isActiveDevice {
            let rustPosition = SpotifyPlayer.positionMs
            let displayedPosition = interpolatedPositionMs
            let displayedLead = Int64(displayedPosition) - Int64(rustPosition)

            let unconfirmedFor = optimisticAnchorTime.map { CACurrentMediaTime() - $0 }
            let correct = switch unconfirmedFor {
            case let .some(elapsed) where elapsed < Self.optimisticAnchorGrace: false
            case .some: abs(displayedLead) > Self.positionDisagreementMs
            case .none: displayedLead > Self.positionDisagreementMs
            }

            // One grace window, one verdict. A measurement clears the mark by arriving,
            // but nothing guarantees one does: a rejected command produces no callback,
            // and a command issued while paused or while a remote device held the floor is
            // not judged here at all. Expiring the mark on the tick that judges it is what
            // stops it outliving its command — otherwise it sits set for the session, and
            // the buffer lead that turns up later reads as evidence of a lost seek.
            if let unconfirmedFor, unconfirmedFor >= Self.optimisticAnchorGrace {
                optimisticAnchorTime = nil
            }

            if correct {
                debugLog("PlaybackViewModel", "Drift correction: \(displayedPosition) -> \(rustPosition)")
                anchorPosition(rustPosition)
                didCorrectDrift = true
            }
        }
    }

    // MARK: - Favorite Management

    /// Toggle favorite status for the currently playing track via the global store.
    ///
    /// A second copy of `TrackService.toggleFavorite`, kept because its callers — the menu bar
    /// item and the ⌘L shortcut — reach the view model and not the services. Worth collapsing
    /// into one when those two get a service; not worth restructuring for this migration.
    func toggleCurrentTrackFavorite() async {
        guard let uri = currentTrackUri, let trackId = SpotifyAPI.parseTrackURI(uri),
              let store
        else { return }

        let wasFavorite = store.isFavorite(trackId)

        // Optimistic update
        if wasFavorite {
            store.removeTrackFromFavorites(trackId)
        } else {
            store.addTrackToFavorites(trackId)
        }

        let uris = ["spotify:track:\(trackId)"]

        do {
            if wasFavorite {
                try await PartnerAPI().removeFromLibrary(uris: uris)
            } else {
                try await PartnerAPI().addToLibrary(uris: uris)
            }
        } catch {
            // Rollback
            if wasFavorite {
                store.addTrackToFavorites(trackId)
            } else {
                store.removeTrackFromFavorites(trackId)
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Volume Persistence

    private func saveVolume() {
        UserDefaults.standard.set(volume, forKey: "playbackVolume")
    }

    // MARK: - Remote Device Volume Sync

    /// Call when Spotifly becomes the active device.
    /// Clears remote volume mode and restores the saved local volume.
    func becameLocalActiveDevice() {
        remoteVolume = nil
        let saved = UserDefaults.standard.double(forKey: "playbackVolume")
        guard saved > 0, volume != saved else { return }
        isSettingVolumeLocally = true
        volume = saved
        isSettingVolumeLocally = false
        SpotifyPlayer.setVolume(volume)
    }

    /// Call when a remote Spotify Connect device becomes active.
    /// Sets remote volume mode so the slider reflects that device's volume.
    func becameRemoteActiveDevice(volumePercent: Int?) {
        remoteVolume = volumePercent.map { Double($0) / 100.0 }
    }

    /// Call when the active remote device's volume is refreshed from HTTP.
    func remoteDeviceVolumeUpdated(_ volumePercent: Int) {
        guard remoteVolume != nil else { return }
        remoteVolume = Double(volumePercent) / 100.0
    }

    /// Subscribe to debounced volume changes
    /// Debounces rapid volume changes (e.g., slider dragging) to avoid flooding Spirc with requests
    private func setupVolumeDebounceSubscription() {
        volumeDebounceSubscription = volumeSubject
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] newVolume in
                guard let self, isInitialized else { return }
                if SpotifyPlayer.isActiveDevice {
                    SpotifyPlayer.setVolume(newVolume)
                } else {
                    let percent = Int((newVolume * 100).rounded())
                    guard let route = connectRoute() else { return }
                    Task {
                        try? await SpclientAPI().setVolume(
                            percent: percent,
                            from: route.from,
                            to: route.to,
                        )
                    }
                }
            }
    }
}
