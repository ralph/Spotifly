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

// MARK: - Drift Correction Timer

/// Helper class for periodic drift correction (not UI updates)
/// Uses a plain Thread with isCancelled check to avoid Swift concurrency issues
private final class DriftCorrectionTimer {
    private var thread: Thread?
    static let checkNotification = Notification.Name("DriftCorrectionCheck")

    func start() {
        let notificationName = DriftCorrectionTimer.checkNotification
        let thread = Thread {
            while !Thread.current.isCancelled {
                Task { @MainActor in
                    NotificationCenter.default.post(name: notificationName, object: nil)
                }
                // Check drift every second (not 100ms - UI uses TimelineView now)
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        thread.name = "com.spotifly.drift-correction"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        thread = nil
    }
}

// MARK: - Playback View Model

@MainActor
@Observable
final class PlaybackViewModel {
    /// Shared singleton instance - ensures only one timer runs
    static let shared = PlaybackViewModel()

    /// Reference to AppStore for reading current track metadata (set by LoggedInView)
    private weak var store: AppStore?

    var isPlaying = false
    var isLoading = false
    var currentTrackUri: String? {
        didSet {
            if oldValue != currentTrackUri {
                trackDurationMs = 0
            }
        }
    }

    private var lastHandledTrackUri: String?
    var errorMessage: String?

    /// Returns the URI of the currently playing track (alias for currentTrackUri)
    var currentlyPlayingURI: String? {
        currentTrackUri
    }

    // Playback state from Mercury (duration/position for progress bar)
    var trackDurationMs: UInt32 = 0
    var currentPositionMs: UInt32 = 0

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
    /// Token provider for reinitialization after session disconnect
    private var tokenProvider: (@Sendable () async -> String)?
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

    /// Sets the token provider for automatic reinitialization after session disconnect.
    func setTokenProvider(_ provider: @escaping @Sendable () async -> String) {
        tokenProvider = provider
    }

    /// Tears down and rebuilds the player even if it is already initialized.
    /// Used by the manual connection retry and by the wake fallback when Rust has no
    /// session to reconnect.
    func forceReinitialize(accessToken: String) async {
        await runInitialization(accessToken: accessToken, force: true)
    }

    /// Initializes the player unless it is already up.
    func initializeIfNeeded(accessToken: String) async {
        await runInitialization(accessToken: accessToken, force: false)
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
    private func runInitialization(accessToken: String, force: Bool) async {
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
            await performInitialization(accessToken: accessToken)
        }
        initializationTask = task
        await task.value
        // Only clear the slot while it is still ours: a logout drops the handle, and a
        // replacement login may already have installed its own by the time this resumes.
        if initializationTask == task {
            initializationTask = nil
        }
    }

    private func performInitialization(accessToken: String) async {
        // We are about to tear down the Rust side, so nothing is initialized until the
        // rebuild proves otherwise. Matters when initialize() throws on a restart.
        isInitialized = false
        isLoading = true
        let generation = lifecycleGeneration
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)

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
        currentPositionMs = 0
        positionAnchorMs = 0
        positionAnchorTime = CACurrentMediaTime()
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

    func play(uriOrUrl: String, trackIndex: Int = -1, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SpotifyPlayer.play(uriOrUrl: uriOrUrl, trackIndex: trackIndex)
            handlePlaybackStarted(trackId: uriOrUrl)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func playTrack(trackId: String, accessToken: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)", accessToken: accessToken)
    }

    func playTracks(_ trackUris: [String], accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        guard !trackUris.isEmpty else {
            errorMessage = "No tracks to play"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SpotifyPlayer.playTracks(trackUris)
            handlePlaybackStarted(trackId: trackUris[0])
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addToQueue(uri: String, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
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

    func togglePlayPause(trackId: String, accessToken: String) async {
        if isPlaying, currentTrackUri == trackId {
            // Route through pause() rather than calling the FFI directly: it carries the
            // connectivity guard and the Web API fallback for remote devices, and it
            // leaves isPlaying to the Mercury callback instead of asserting it here
            pause()
        } else if !isPlaying, currentTrackUri == trackId {
            resume()
        } else {
            // Play new track
            await playTrack(trackId: trackId, accessToken: accessToken)
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
    }

    // MARK: - Playback Control (via Spirc or Web API)

    /// Issues a transport command locally when Spotifly is the active device, and through
    /// the Web API otherwise. Returns whether the command was issued at all.
    ///
    /// The local branch is gated on the session being connected: during a reconnect Rust
    /// rejects commands, and the callers that move the UI optimistically must not do so for
    /// a command that never happened — hence the `Bool` rather than a plain dispatch.
    /// The remote branch reports failures through `errorMessage`; the local branch leaves
    /// the resulting playback state to the Mercury callback.
    @discardableResult
    private func sendTransportCommand(
        _ name: String,
        local: () -> Void,
        remote: @escaping (String) async throws -> Void,
    ) -> Bool {
        guard SpotifyPlayer.isActiveDevice else {
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await remote(token)
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

    func next() {
        guard sendTransportCommand(
            "next()",
            local: { SpotifyPlayer.next() },
            remote: { try await SpotifyAPI.skipToNext(accessToken: $0) },
        ) else {
            return
        }

        // Immediately reset position to 0 for responsive UI
        positionAnchorMs = 0
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = 0
        updateNowPlayingInfo()
    }

    func previous() {
        guard sendTransportCommand(
            "previous()",
            local: { SpotifyPlayer.previous() },
            remote: { try await SpotifyAPI.skipToPrevious(accessToken: $0) },
        ) else {
            return
        }

        // Immediately reset position to 0 for responsive UI
        positionAnchorMs = 0
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = 0
        updateNowPlayingInfo()
    }

    func seek(to positionMs: UInt32) {
        // Update anchor immediately for smooth UI feedback during scrubbing
        positionAnchorMs = positionMs
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = positionMs
        updateNowPlayingPosition()

        // Debounce the actual seek operation to avoid flooding Spirc/API with requests
        seekSubject.send(positionMs)
    }

    func pause() {
        // State update will come from Mercury callback
        sendTransportCommand(
            "pause()",
            local: { SpotifyPlayer.pause() },
            remote: { try await SpotifyAPI.pausePlayback(accessToken: $0) },
        )
    }

    func resume() {
        guard sendTransportCommand(
            "resume()",
            local: { SpotifyPlayer.resume() },
            remote: { try await SpotifyAPI.resumePlayback(accessToken: $0) },
        ) else {
            return
        }

        // Don't call syncPositionAnchor() - Rust returns 0 immediately after resume
        // Keep the current positionAnchorMs (correct from paused state), just update the time
        positionAnchorTime = CACurrentMediaTime()
        updateNowPlayingPosition()
    }

    func toggleShuffle() {
        let targetShuffle = !isShuffleEnabled

        sendTransportCommand(
            "toggleShuffle()",
            local: { SpotifyPlayer.setShuffle(targetShuffle) },
            remote: { try await SpotifyAPI.setShuffle(accessToken: $0, enabled: targetShuffle) },
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
    /// because a rebuild cleared the position would be worse than holding the last shown
    /// value — so a zero is only adopted when we have no anchor of our own either.
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

        positionAnchorMs = frozenPosition
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = trackDurationMs > 0
            ? min(frozenPosition, trackDurationMs)
            : frozenPosition
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
                let posMs = notification.positionMs
                positionAnchorMs = posMs
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = posMs

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
            remote: { try await SpotifyAPI.seekToPosition(accessToken: $0, positionMs: Int(positionMs)) },
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

        // Update duration
        if state.durationMs > 0 {
            trackDurationMs = UInt32(state.durationMs)
        }
        let receivedFirstStreamDuration = !hadStreamDuration && trackDurationMs > 0

        isShuffleEnabled = state.shuffle

        // Sync position anchor on state changes
        // When monitoring a remote device, position_ms is the position at timestamp_ms
        // We need to account for elapsed time since that timestamp to get current position
        if state.positionMs >= 0 {
            let posMs = UInt32(state.positionMs)
            let now = CACurrentMediaTime()

            // If we have a valid timestamp, adjust anchor time backwards by elapsed time
            // This makes interpolation give the correct current position
            if state.timestampMs > 0 {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let elapsedSinceTimestamp = max(0, nowMs - state.timestampMs)
                let elapsedSeconds = Double(elapsedSinceTimestamp) / 1000.0
                debugLog("PlaybackViewModel", "Position anchor: \(positionAnchorMs) -> \(posMs) (timestamp was \(elapsedSinceTimestamp)ms ago)")
                positionAnchorMs = posMs
                positionAnchorTime = now - elapsedSeconds
            } else {
                debugLog("PlaybackViewModel", "Position anchor: \(positionAnchorMs) -> \(posMs)")
                positionAnchorMs = posMs
                positionAnchorTime = now
            }
            currentPositionMs = posMs
        }

        // Update Now Playing position if playback rate changed, or if track changed
        if trackChanged || receivedFirstStreamDuration {
            updateNowPlayingInfo()
        } else if wasPlaying != isPlaying {
            updateNowPlayingPosition()
        }
    }

    /// Apply playback state from Web API (used for initial sync when Spirc connects).
    /// This populates the UI with the current playback state from any active device.
    func applyWebAPIPlaybackState(
        isPlaying: Bool,
        progressMs: Int,
        durationMs: Int,
        trackUri: String?,
        timestampMs: Int64,
        shuffleEnabled: Bool,
    ) {
        debugLog(
            "PlaybackViewModel",
            "Applying Web API state: playing=\(isPlaying), progress=\(progressMs)ms, duration=\(durationMs)ms, shuffle=\(shuffleEnabled), uri=\(trackUri ?? "nil")",
        )

        // Update playing state
        self.isPlaying = isPlaying
        isShuffleEnabled = shuffleEnabled

        // Update track if provided
        if let uri = trackUri, !uri.isEmpty {
            currentTrackUri = uri
            lastHandledTrackUri = uri
        }

        // Update duration
        if durationMs > 0 {
            trackDurationMs = UInt32(durationMs)
        }

        // Set position anchor accounting for elapsed time since the API timestamp.
        // The API timestamp is when Spotify last received a state change — it can be
        // arbitrarily stale during uninterrupted playback. If compensation would push
        // the position past the track end, discard it and anchor at progress_ms directly.
        if progressMs >= 0 {
            let posMs = UInt32(progressMs)
            let now = CACurrentMediaTime()

            if timestampMs > 0 {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let elapsedMs = max(0, nowMs - timestampMs)
                let compensated = Int64(progressMs) + elapsedMs
                let stale = durationMs > 0 && compensated > Int64(durationMs)
                if stale {
                    debugLog("PlaybackViewModel", "Web API position anchor: \(posMs)ms (timestamp was \(elapsedMs)ms ago, stale — ignoring compensation)")
                } else {
                    debugLog("PlaybackViewModel", "Web API position anchor: \(posMs)ms (timestamp was \(elapsedMs)ms ago)")
                }
                positionAnchorMs = posMs
                positionAnchorTime = stale ? now : now - Double(elapsedMs) / 1000.0
            } else {
                positionAnchorMs = posMs
                positionAnchorTime = now
            }
            currentPositionMs = posMs
        }

        // Update Now Playing info
        updateNowPlayingInfo()
    }

    // MARK: - Position Tracking

    // Anchor-based position tracking using CACurrentMediaTime for precision
    // UI reads interpolatedPositionMs (computed), not currentPositionMs directly
    private var positionAnchorMs: UInt32 = 0
    private var positionAnchorTime: Double = CACurrentMediaTime()
    private var driftCorrectionTimer: DriftCorrectionTimer?
    private var driftObserver: NSObjectProtocol?

    /// Computed position using anchor interpolation - UI should bind to this
    /// Called by TimelineView on every frame for smooth updates
    var interpolatedPositionMs: UInt32 {
        guard isPlaying, isConnectionReady else { return currentPositionMs }
        let elapsed = CACurrentMediaTime() - positionAnchorTime
        let elapsedMs = UInt32(max(0, min(elapsed * 1000, Double(UInt32.max - 1))))
        let interpolated = positionAnchorMs.addingReportingOverflow(elapsedMs).partialValue
        // Don't clamp to 0 if duration is unknown yet
        guard trackDurationMs > 0 else { return interpolated }
        return min(interpolated, trackDurationMs)
    }

    private func startPositionTimer() {
        let timer = DriftCorrectionTimer()

        // Observe drift correction notifications
        driftObserver = NotificationCenter.default.addObserver(
            forName: DriftCorrectionTimer.checkNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkDriftAndSync()
            }
        }

        timer.start()
        driftCorrectionTimer = timer
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
        positionAnchorMs = rustPosition
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = rustPosition
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
        if SpotifyPlayer.isActiveDevice {
            let rustPosition = SpotifyPlayer.positionMs
            let drift = abs(Int64(rustPosition) - Int64(interpolatedPositionMs))
            if drift > 500 {
                positionAnchorMs = rustPosition
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = trackDurationMs > 0
                    ? min(rustPosition, trackDurationMs)
                    : rustPosition
                didCorrectDrift = true
            }
        }
    }

    // MARK: - Favorite Management

    /// Toggle favorite status for the currently playing track via the global store.
    func toggleCurrentTrackFavorite(accessToken: String) async {
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

        do {
            if wasFavorite {
                try await SpotifyAPI.removeSavedTrack(accessToken: accessToken, trackId: trackId)
            } else {
                try await SpotifyAPI.saveTrack(accessToken: accessToken, trackId: trackId)
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
                    Task { [weak self] in
                        guard let token = await self?.tokenProvider?() else { return }
                        try? await SpotifyAPI.setVolume(accessToken: token, percent: percent)
                    }
                }
            }
    }
}
