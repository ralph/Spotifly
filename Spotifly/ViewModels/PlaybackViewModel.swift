//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import Combine
import MediaPlayer
import SwiftUI

// MARK: - Playback View Model

@MainActor
@Observable
final class PlaybackViewModel {
    /// Shared singleton instance - ensures only one timer runs
    static let shared = PlaybackViewModel()

    /// What the player last published.
    private let player = PlayerModel.shared

    /// The session's store, for reading the current track's metadata; see `attach`.
    private weak var store: AppStore?

    /// What ⌘L's favorite toggle goes through. Weak like the store, so a logout does not keep
    /// the old account's service and store alive in this process-wide model.
    private weak var trackService: TrackService?

    /// Set when a play request arrived with nowhere to serve it: no local player and no
    /// active remote device. The view presents the Auth / Cancel alert on this.
    var needsStreamingAuthorization = false
    /// Raised by the first play this Mac cannot start because the account is not Premium,
    /// for the notice that offers Logout.
    var showsPremiumNotice = false

    var isLoading = false

    /// What the bar shows of the player's playback: its last report that had any, stopped if
    /// a later one had none. A nil report keeps the track, for a failed load or another device
    /// taking over, and with it the options it played with, which reading `player.playback`
    /// lost.
    ///
    /// A copy, deliberately, written in the same call as the position anchor
    /// (`handlePlaybackStateUpdate`) and cleared with it (`clearPlaybackState`): read from
    /// `player.playback` instead, it would change at the player model's `apply`, one
    /// `Observations` delivery before the anchor, and a frame drawn in between runs a paused
    /// anchor on or stops a playing one. It holds no position, so a report that only moves the
    /// position is an equal write, which the lists that mark the playing row do not hear; a
    /// pause, a change of shuffle or a length arriving still reach them, once each.
    private var shown: ShownPlayback?

    private struct ShownPlayback: Equatable {
        var trackUri: String
        /// `trackUri`'s id, parsed once with the report rather than on each read.
        var trackId: String?
        /// Playing and not paused, for this Mac's player and for a device it mirrors alike.
        var isPlaying: Bool
        /// Zero until the stream reports this track's length, and never the previous track's:
        /// a report that names none keeps the one this track had, or none on a new track.
        /// `clampedToTrack` and `positionAnchor(forPosition:takenAt:)` rely on it.
        var durationMs: UInt32
        var shuffle: Bool
        /// See `PlaybackState.canSkipNext`.
        var canSkipNext: Bool
        /// See `PlaybackState.canShuffle`.
        var canShuffle: Bool
    }

    var isPlaying: Bool {
        shown?.isPlaying ?? false
    }

    var currentTrackUri: String? {
        shown?.trackUri
    }

    /// The error the now-playing bar shows in place of the track's title. Views set it too,
    /// for favorite and playlist failures. It clears itself after five seconds, here rather
    /// than in the bar, because the bar is not always mounted: with the window closed, media
    /// keys and ⌘L still reach this model, and an error from then must not greet its reopening.
    var errorMessage: String? {
        didSet {
            guard let errorMessage, errorMessage != oldValue else { return }
            errorMessageExpired = false
            // A caption changing in place is not announced by itself.
            AccessibilityNotification.Announcement(errorMessage).post()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.errorMessage == errorMessage else { return }
                if isErrorMessageHeld {
                    errorMessageExpired = true
                } else {
                    self.errorMessage = nil
                }
            }
        }
    }

    /// Set by the bar while the pointer is on the error. The bar cuts off what does not fit,
    /// and the error is read in full by pointing at it, so it stays past its five seconds
    /// until the pointer leaves.
    var isErrorMessageHeld = false {
        didSet {
            if !isErrorMessageHeld, errorMessageExpired {
                errorMessage = nil
            }
        }
    }

    /// Whether the error's five seconds ran out while it was held.
    private var errorMessageExpired = false

    /// Length of the current track, as the stream reports it; see `ShownPlayback.durationMs`.
    /// The position that goes with it is derived from the anchor rather than stored alongside;
    /// see `interpolatedPositionMs`.
    private var trackDurationMs: UInt32 {
        shown?.durationMs ?? 0
    }

    /// This Mac's volume (0–1), and only this Mac's: what its output plays at, what it
    /// registers at on Spotify Connect, and what is saved. A slider move made for another
    /// device does not touch it (`setVolumeFromSlider`).
    var volume: Double = 0.5 {
        didSet {
            // Apply the output gain immediately (not debounced) so local volume
            // changes are audible at once instead of after the render buffer drains.
            SpotifyPlayer.setOutputVolume(volume)
            // Not sent back when it came from the client (`handleVolumeChange`).
            guard !isSettingVolumeLocally else { return }
            // Debounced on to the client, and saved there, so a drag is one request and one
            // write rather than one a frame.
            volumeSubject.send(volume)
        }
    }

    /// What the bar's slider shows: the active remote device's volume while another device
    /// plays, this Mac's otherwise.
    ///
    /// Read from the player model, not kept: a copy kept up by the window's `onChange`s went
    /// stale in the mini player, which has none, and showed one device's volume while moving
    /// the other's. A drag shows its own value until the device reports a new volume.
    var sliderVolume: Double {
        guard let deviceId = player.activeRemoteDeviceId else { return volume }
        let reported = player.activeDevice?.volumePercent
        if let dragged = draggedRemoteVolume, dragged.deviceId == deviceId,
           dragged.reportedPercent == reported
        {
            return dragged.volume
        }
        // Unknown only while the device list has not caught up with the active id.
        return reported.map { Double($0) / 100 } ?? volume
    }

    /// Whether the device the slider moves refuses volume changes. Only ever another device:
    /// this Mac's volume is the app's own. An iPhone says so, as iOS will not let one app set
    /// system volume for another; the app used to find out from the
    /// `400 DEVICE_DOES_NOT_SUPPORT_COMMAND` its command got back, after the user had dragged.
    var sliderRefused: Bool {
        player.activeRemoteDeviceId != nil && player.activeDevice?.disableVolume == true
    }

    /// Moves what the slider shows: the active remote device's volume while another device
    /// plays, this Mac's otherwise.
    ///
    /// Both used to be written: `volume` followed a remote device's slider too, so this Mac's
    /// output gain did, and taking playback back here had to restore it from what was saved.
    func setVolumeFromSlider(_ newVolume: Double) {
        guard let deviceId = player.activeRemoteDeviceId else {
            volume = newVolume
            return
        }
        draggedRemoteVolume = DraggedVolume(
            deviceId: deviceId,
            volume: newVolume,
            reportedPercent: player.activeDevice?.volumePercent,
        )
        remoteVolumeSubject.send(newVolume)
    }

    /// A drag of another device's volume, which the slider shows ahead of the device's report.
    private struct DraggedVolume {
        let deviceId: String
        let volume: Double
        /// What the device reported when the drag moved; a report since replaces the drag.
        let reportedPercent: Int?
    }

    private var draggedRemoteVolume: DraggedVolume?

    var isShuffleEnabled: Bool {
        shown?.shuffle ?? false
    }

    /// Whether the client has completed at least one usable initialization.
    /// This stays true through transient disconnects, because `LibrespotClient`
    /// recovers from those itself.
    private var isInitialized = false

    /// Whether this Mac can play audio itself, and if not, what would change that.
    nonisolated enum LocalPlayback: Equatable {
        case ready
        /// No usable session. Authorizing streaming is the fix.
        case needsAuthorization
        /// Spotify named the account other than Premium at login, or refused the login for
        /// want of it. Nothing in the app fixes that; the library, search and other devices'
        /// playback work as ever.
        case needsPremium
    }

    /// Anything asking "is this Mac a playback device" wants this.
    ///
    /// Cached credentials existing on disk is not the same fact: they can be revoked or
    /// stale, in which case initialization fails and the app must still offer to
    /// re-authorize.
    var localPlayback: LocalPlayback {
        if player.connection?.streams == false {
            return .needsPremium
        }
        return isInitialized ? .ready : .needsAuthorization
    }

    /// Whether this launch has raised the notice already.
    private var hasShownPremiumNotice = false

    /// Whether the session is up, and with it the cluster that reports another device's
    /// playback.
    private var isConnectionReady = false

    /// Whether the displayed position runs on. A local track plays on while the session
    /// reconnects, from the pipeline's memory; another device's position arrives over the
    /// session, and holds while it is down.
    private var positionRuns: Bool {
        isPlaying && (isConnectionReady || SpotifyPlayer.isActiveDevice)
    }

    private var lastAlbumArtURL: String?
    /// Flag to prevent feedback loop when we set volume locally
    private var isSettingVolumeLocally = false
    /// This Mac's volume changes, debounced on their way to the client
    private let volumeSubject = PassthroughSubject<Double, Never>()
    /// The active remote device's, debounced on their way to it
    private let remoteVolumeSubject = PassthroughSubject<Double, Never>()
    /// Subscriptions for the two debounced volumes
    private var volumeDebounceSubscriptions: Set<AnyCancellable> = []
    /// Subject for debouncing seek requests
    private let seekSubject = PassthroughSubject<UInt32, Never>()
    /// Subscription for debounced seek operations
    private var seekSubscription: AnyCancellable?
    /// The in-flight initialization or restart, so concurrent callers coalesce onto one
    private var initializationTask: Task<Void, Never>?

    /// Bumped when a logout invalidates whatever the player lifecycle is doing. Mirrors
    /// the client's own lifecycle generation: an initialization already inside
    /// `SpotifyPlayer.initialize` is not cancelled, so it has to be caught on the way out
    /// instead.
    private var lifecycleGeneration: UInt64 = 0

    /// True while a logout teardown is running. Suppresses the readiness adoption below: a
    /// snapshot published before the client's connection state catches up would mark the player
    /// initialized again, and the disconnected snapshots that follow deliberately do not
    /// clear that flag — so the next account would skip initialization entirely.
    private var isLoggingOut = false

    /// The logout teardown in flight, if any. Later callers await it rather than starting a
    /// second one — two would each reset `isLoggingOut` on their own way out, so the first
    /// to finish would reopen the door while the other was still tearing down.
    private var logoutTask: Task<Void, Never>?

    private init() {
        observePlayer()
        setupVolumeDebounceSubscription()
        setupSeekSubscription()
        setupRemoteCommandCenter()
        observeSystemSleep()

        volume = Self.savedVolume

        // Set initial Now Playing info to claim media controls
        var initialInfo: [String: Any] = [:]
        initialInfo[MPMediaItemPropertyTitle] = Self.unresolvedTrackTitle
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        // Start position update timer
        startPositionTimer()
    }

    /// Tears down and rebuilds the player even if it is already initialized.
    /// Used by the manual connection retry and by the wake fallback when the client has no
    /// session to reconnect.
    func forceReinitialize() async {
        await runInitialization(force: true)
    }

    /// Initializes the player unless it is already up, or Spotify refused it for want of
    /// Premium, as it would again. Reconnect in Speakers still tries.
    func initializeIfNeeded() async {
        guard localPlayback != .needsPremium else { return }
        await runInitialization(force: false)
    }

    /// Tears the streaming session down on logout, and forgets what it played: every way out
    /// of the account comes through here (`AuthViewModel.logout`), a revoked grant as well as
    /// Log Out.
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
            hasShownPremiumNotice = false
            isLoggingOut = true
            defer { isLoggingOut = false }

            await endSession()
        }
        logoutTask = task
        await task.value
        logoutTask = nil
    }

    /// Serializes every initialization and restart through one in-flight task.
    ///
    /// `@MainActor` stops two of these running *simultaneously*, but not from
    /// *overlapping*: every `await` is a suspension point where another caller can enter,
    /// and `SpotifyPlayer.initialize` tears the session down before rebuilding it. Two
    /// overlapping calls can therefore interleave one call's teardown with the other's
    /// rebuild, which is how this view model ends up holding state belonging to a session
    /// that has already been replaced.
    ///
    /// Late callers await the in-flight run instead of starting a competing one. That also
    /// coalesces concurrent explicit rebuild requests, for which one rebuild is the correct
    /// response.
    private func runInitialization(force: Bool) async {
        // Nothing may build a player while one is being torn down. The view is still mounted
        // during a logout, so a playback action or a startup task can land here — and it
        // would capture the already-bumped lifecycle generation, so the stale-run check
        // would wave it through while `LibrespotClient.initialize` clears its own shutdown
        // flag on the way in, re-announcing the account that just logged out.
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
        // We are about to tear the session down, so nothing is initialized until the
        // rebuild proves otherwise. Matters when initialize() throws on a restart.
        isInitialized = false
        isLoading = true
        // Cleared before the rebuild, not after: the new session can report a track while it
        // is being built, such as another device's paused one, and the player model passes on
        // changes only, so a later reset would erase it for good.
        clearPlaybackState()
        let generation = lifecycleGeneration
        do {
            try await SpotifyPlayer.initialize(volume: volume)

            // Readiness is the authoritative condition, not "initialize() returned". The
            // old code set isInitialized as soon as `initialize()` returned and then polled
            // Spirc while ignoring the timeout, so Swift could permanently believe the
            // player was up while every Connect command failed — and initializeIfNeeded
            // would then refuse to try again. Leaving the flag false on timeout means the
            // next caller retries.
            if await waitUntilReady() {
                isInitialized = true
                errorMessage = nil
            } else {
                debugLog("PlaybackViewModel", "Player did not become ready within \(Self.readinessTimeout)")
                errorMessage = String(localized: "error.player_not_ready")
            }
        } catch LibrespotError.premiumRequired {
            // Said when a play is aimed here, as for a free account that logged in; the
            // client published it.
        } catch {
            errorMessage = error.localizedDescription
        }

        // Checked on both paths on purpose. `LibrespotClient.initialize` clears its own
        // shutdown flag on the way in, so an initialization that overlapped a logout can
        // bring a session up for an account that is gone. The client notices that itself
        // only when its generation moved before it finished — and then it throws, which is
        // why the failure path has to be checked too. A logout landing after its last check
        // leaves a live session behind, and only this view model knows one happened.
        if generation != lifecycleGeneration {
            debugLog("PlaybackViewModel", "Initialization outlived a logout — tearing it back down")
            await endSession()
            isInitialized = false
            errorMessage = nil
        }
        isLoading = false
    }

    /// Takes this Mac off Spotify Connect and forgets what the session played, which belongs
    /// to an account that is leaving.
    ///
    /// Forgets after the teardown, whose last report has no playback: a report still on its
    /// way would otherwise put the track back, and one without playback keeps it.
    private func endSession() async {
        await SpotifyPlayer.shutdownAndCleanup()
        clearPlaybackState()
    }

    /// Forgets the track: publishes the stopped rate before clearing the URI, then removes
    /// the old track's metadata.
    private func clearPlaybackState() {
        shown?.isPlaying = false
        updateNowPlayingPosition()
        shown = nil
        updateNowPlayingInfo()
        anchorPosition(0)
    }

    /// How long to wait for the player to become usable after initialization.
    private static let readinessTimeout: Duration = .seconds(5)

    /// Polls until the client reports a connected session, or the timeout expires.
    private func waitUntilReady() async -> Bool {
        let deadline = ContinuousClock.now + Self.readinessTimeout
        while ContinuousClock.now < deadline {
            if SpotifyPlayer.isSessionConnected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return SpotifyPlayer.isSessionConnected
    }

    /// Where a play request should go.
    enum PlaybackTarget: Equatable {
        case local
        case remote(deviceId: String)
        case needsAuthorization
        case needsPremium
    }

    /// Decides where to play.
    ///
    /// Local wins when it exists; otherwise an active remote device serves the request over
    /// connect-state. Only when neither exists is there anything to tell the user —
    /// nagging about local streaming while a phone is playing would be noise — and what
    /// depends on why this Mac cannot play.
    nonisolated static func playbackTarget(local: LocalPlayback, activeDeviceId: String?) -> PlaybackTarget {
        if local == .ready {
            return .local
        }
        if let activeDeviceId {
            return .remote(deviceId: activeDeviceId)
        }
        return local == .needsPremium ? .needsPremium : .needsAuthorization
    }

    /// Plays a track or a context. A row in a list passes its index and its track; see
    /// `PlaybackQueue.start(in:index:uri:)`.
    func play(uriOrUrl: String, trackIndex: Int? = nil, startingAtUri: String? = nil) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        let target = resolvedPlaybackTarget()
        switch target {
        case .local:
            await startLocally {
                try await SpotifyPlayer.play(uriOrUrl: uriOrUrl, trackIndex: trackIndex, startingAtUri: startingAtUri)
            }

        case let .remote(deviceId):
            // One uri either way: the command's own context builder tells a track from a
            // context, where the Web API needed the caller to split them into two fields.
            await startRemotely(
                .play(uri: Self.remoteStartUri(for: uriOrUrl), trackIndex: trackIndex, trackUri: startingAtUri),
                deviceId: deviceId,
            )

        case .needsAuthorization, .needsPremium:
            explain(target)
        }
    }

    func playTrack(trackId: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)")
    }

    func playTracks(_ trackUris: [String]) async {
        if !isInitialized {
            await initializeIfNeeded()
        }

        // The one caller disables its button on an empty list, so this only guards `[0]`.
        guard !trackUris.isEmpty else { return }

        let target = resolvedPlaybackTarget()
        switch target {
        case .local:
            await startLocally {
                try await SpotifyPlayer.playTracks(trackUris)
            }

        case let .remote(deviceId):
            await startRemotely(
                .play(trackUris: trackUris),
                deviceId: deviceId,
            )

        case .needsAuthorization, .needsPremium:
            explain(target)
        }
    }

    /// Starts song radio, which only the local player can do.
    ///
    /// Radio is a Spirc feature with no Web API equivalent, so unlike `play` it cannot fall
    /// back to a remote device. Without a local player the command was previously issued
    /// anyway and its failure discarded with it, so track cards and context menus silently
    /// did nothing; asking for authorization is the honest answer.
    func playRadio(trackUri: String) async {
        // A track Spotify will not play starts nothing, radio included, wherever it is
        // clicked: a search card, a row or its menu.
        if let message = SpotifyAPI.parseTrackURI(trackUri).flatMap({ store?.tracks[$0] })?.unplayableMessage {
            errorMessage = message
            return
        }

        if !isInitialized {
            await initializeIfNeeded()
        }

        // No remote device: radio has no connect-state command.
        let target = Self.playbackTarget(local: localPlayback, activeDeviceId: nil)
        guard target == .local else {
            explain(target)
            return
        }

        do {
            try await SpotifyPlayer.playRadio(trackUri: trackUri)
        } catch is CancellationError {
            // Another start overtook this one; it reports for itself.
        } catch {
            debugLog("PlaybackViewModel", "Radio for \(trackUri) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
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
        Self.playbackTarget(local: localPlayback, activeDeviceId: player.activeDeviceId)
    }

    /// Says why a play found nowhere to go. Without a session, by offering to authorize.
    /// For an account that may not play here, in the bar, and the first time also with the
    /// notice, which offers Logout. The bar every time, because the mini player shows the
    /// bar and not the notice.
    private func explain(_ target: PlaybackTarget) {
        switch target {
        case .needsAuthorization:
            needsStreamingAuthorization = true
        case .needsPremium:
            errorMessage = LibrespotError.premiumRequired.localizedDescription
            if !hasShownPremiumNotice {
                hasShownPremiumNotice = true
                showsPremiumNotice = true
            }
        case .local, .remote:
            break
        }
    }

    /// Runs a local Spirc start and folds its outcome into `isLoading` / `errorMessage`.
    ///
    /// `play` and `playTracks` differ only in the call they make, so the state-keeping around it
    /// is written once. The remote half is `startRemotely` below.
    private func startLocally(_ start: @MainActor () async throws -> Void) async {
        isLoading = true
        errorMessage = nil

        do {
            try await start()
            // The track, whether it plays and where are the player's reports, which anchor the
            // position as they come: every load ends in one that says playing or paused, and
            // the start returns between the first and that one (measured).
        } catch is CancellationError {
            // Another start overtook this one; it reports for itself.
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Starts content on a remote device. The cluster reports what it plays, and the bar and
    /// the queue follow it through the player model.
    private func startRemotely(
        _ command: ConnectCommand,
        deviceId: String,
    ) async {
        guard let from = player.ownDeviceId, !from.isEmpty else {
            errorMessage = String(localized: "error.no_playback_device")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await SpclientAPI().sendCommand(command, from: from, to: deviceId)
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
            errorMessage = String(localized: "error.player_not_initialized")
            return
        }

        errorMessage = nil

        // Queued where playback is. While another device plays, the queue on screen is its
        // queue, mirrored — adding to this Mac's own, which nothing was playing from, changed
        // nothing anyone could see or hear. connect-state queues one track per command, so an
        // album or playlist goes as its tracks, in order.
        let issued = sendTransportCommand(
            "addToQueue()",
            local: { SpotifyPlayer.addToQueue(uri: uri) },
            remote: { from, to in
                for track in try await SpotifyPlayer.queueableTracks(for: uri) {
                    try await SpclientAPI().sendCommand(.addToQueue(trackUri: track), from: from, to: to)
                }
            },
        )

        // With nobody active and no session there is nothing to command, but the local queue
        // does not need one: it is what playback continues from once the session is back.
        // Nothing continues from it for an account that does not stream here.
        if !issued, localPlayback != .needsPremium {
            SpotifyPlayer.addToQueue(uri: uri)
        }
    }

    // MARK: - Session

    /// Gives the model the session's store and track service (`LoggedInSession`), as the account
    /// signs in (`AuthViewModel.startSession`). Held weakly, so ending the session at a logout
    /// frees them.
    func attach(store: AppStore, trackService: TrackService) {
        self.store = store
        self.trackService = trackService
    }

    // MARK: - Playback Control (via Spirc or connect-state)

    /// Issues a transport command locally when Spotifly is the active device, and through
    /// connect-state otherwise. Returns whether the command was issued at all.
    ///
    /// While this device is active the command goes to the local player even mid-reconnect:
    /// the pipeline plays on from memory and needs no session to pause, resume or seek, and
    /// a track it has to fetch for Next or Previous waits for the session to come back.
    ///
    /// With nobody active and no session, nothing is issued, and the callers that move the
    /// UI optimistically must not do so for a command that never happened, hence the
    /// `Bool` rather than a plain dispatch. Both branches report a failure through
    /// `errorMessage`; the resulting playback state is left to what the client publishes.
    ///
    /// `isActiveDevice` is two-valued and the cluster is not: Spotifly is active, another
    /// device is, or **nobody** is. The third state is reached routinely — waking from sleep
    /// gets there, because the session that comes back registers itself as inactive and the
    /// cluster update that answers then names nobody at all.
    ///
    /// **That state used to be found out by asking**: the Web API answered 404 and the 404 was
    /// caught. connect-state addresses the target in the *url*, so with nobody active there is
    /// no url to build — the same condition, now a precondition instead of a round trip, and
    /// one fewer request on a path the user is waiting on.
    ///
    /// What the local fallback recovers is **resume**, which is also the only one that needs
    /// recovering. A paused pipeline still holds its track, so resuming plays on from where
    /// it stopped; with nothing loaded here, the client takes over the track another device
    /// left, which the bar mirrors. Either way the playing state that follows is reported to
    /// Spirc as this device being active, which takes the Connect role back with it. The others reach a pipeline
    /// that is stopped or empty and do nothing — and that is the right outcome rather than a
    /// gap to close: with nobody active there is no track playing, so there is nothing to
    /// pause, skip or seek. Activating for them would take the Connect role away from the
    /// user's other clients in order to accomplish nothing, and making them work would mean
    /// silently starting playback in response to "next" or "seek" — a different feature, not
    /// this fix.
    ///
    /// `promisesPosition` marks the commands whose caller moves the display ahead of
    /// playback — skips and seeks — and so have a promise to withdraw if they fail. Any
    /// other command leaves a promise standing, including one a seek still in flight made.
    @discardableResult
    private func sendTransportCommand(
        _ name: String,
        promisesPosition: Bool = false,
        local: @escaping () async throws -> Void,
        remote: @escaping (_ from: String, _ to: String) async throws -> Void,
        declined: @escaping (SpclientError) -> Void = { _ in },
    ) -> Bool {
        let command: () async throws -> Void
        if SpotifyPlayer.isActiveDevice {
            command = local
        } else if let route = connectRoute() {
            command = { try await remote(route.from, route.to) }
        } else if SpotifyPlayer.isSessionConnected {
            // Nothing out there to command, so command ourselves. The playback state that
            // follows is reported to Spirc as this device being active, so the Connect role
            // comes back with it — which is what pressing a transport control with no device
            // active asks for. Unless this Mac may not play for the account.
            guard localPlayback != .needsPremium else {
                debugLog("PlaybackViewModel", "\(name) had no active device, and this account does not stream here")
                explain(.needsPremium)
                return false
            }
            debugLog("PlaybackViewModel", "\(name) had no active device - running locally")
            command = local
        } else {
            debugLog("PlaybackViewModel", "\(name) dropped - no active device and session not connected")
            return false
        }

        Task {
            // Where the caller moved the display ahead of playback for this command.
            // Callers anchor after this returns, and this runs after them.
            let promise = promisesPosition ? optimisticAnchorTime : nil
            do {
                try await command()
            } catch is CancellationError {
                // A newer load took over, as a second skip does; it reports for itself.
            } catch {
                if let error = error as? SpclientError, error.isDeclined {
                    // Spotify refusing on its own terms — no track to go back to, or a device
                    // that will not take the command. The user pressed a control deliberately
                    // and nothing is broken, so this is a log line rather than an error banner.
                    debugLog("PlaybackViewModel", "\(name) declined: \(error.localizedDescription)")
                    declined(error)
                } else {
                    debugLog("PlaybackViewModel", "\(name) failed: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
                withdraw(promise)
            }
        }
        return true
    }

    /// Puts the display back where playback is, after a command that moved it ahead failed.
    ///
    /// Nothing reports back a command that did not happen, and another device's position is
    /// not drift-checked, so the display stayed where the command had promised. It used to be
    /// put back by chance, when the next cluster push re-sent the unchanged playback state;
    /// the player model passes on only what changed. Left alone once a newer command has
    /// moved the display, or a measurement has replaced the promise.
    private func withdraw(_ promise: Double?) {
        guard let promise, optimisticAnchorTime == promise else { return }
        debugLog("PlaybackViewModel", "Withdrawing the position a failed command promised")
        handlePlaybackStateUpdate(player.playback)
    }

    /// Who to address a connect-state command as, and to. Nil when nothing is active.
    ///
    /// `from` is our own device id. The backend does not validate that segment — it derives the
    /// source from the session, which is why librespot's transfer passes its own id for both
    /// sides — so this is an identifier for their logs rather than a routing decision.
    private func connectRoute() -> (from: String, to: String)? {
        guard let to = player.activeDeviceId, !to.isEmpty,
              let from = player.ownDeviceId, !from.isEmpty
        else { return nil }

        return (from, to)
    }

    func next() {
        skip("next()", local: { try await SpotifyPlayer.next() }, remote: .next)
    }

    /// Previous track, or the start of this one, so the bar enables it whenever a track is loaded.
    ///
    /// With no earlier track, restarting is what pressing it means, and the local player does
    /// exactly that. A remote device does not: `skip_prev` comes back `403 no_prev_track`,
    /// which left the button enabled and doing nothing while an error banner blamed Spotify.
    /// So the refusal is answered with the seek it stood for.
    func previous() {
        skip("previous()", local: { try await SpotifyPlayer.previous() }, remote: .previous) { [weak self] error in
            guard error.isNoPreviousTrack else { return }
            self?.seek(to: 0)
        }
    }

    /// A row of the queue, as a double-click names it: which list, where in it, and its track.
    enum QueueRow {
        case previous(index: Int, trackUri: String, uid: String?)
        case current
        /// One of the next tracks, with its row's uid where it has one.
        case next(index: Int, trackUri: String, uid: String?)
    }

    /// Plays a row of the queue and keeps the queue. Another device gets the web player's
    /// `skip_next` naming the row. Connect has no way back to a named track, so there a
    /// previous row starts the context from it.
    func play(queueRow row: QueueRow) {
        switch row {
        case .current:
            seek(to: 0)
            if !isPlaying {
                resume()
            }
        case let .next(index, uri, uid):
            skip(
                "skip(toNext:)",
                local: { try await SpotifyPlayer.skip(toNext: index, uri: uri, uid: uid) },
                remote: .skipNext(to: uri, uid: uid),
            )
        case let .previous(index, uri, uid):
            skip(
                "skip(toPrevious:)",
                local: { try await SpotifyPlayer.skip(toPrevious: index, uri: uri, uid: uid) },
                remote: .play(uri: player.queue?.context ?? uri, trackUri: uri),
            )
        }
    }

    /// A command that moves to another track, whose start the display shows at once.
    private func skip(
        _ name: String,
        local: @escaping () async throws -> Void,
        remote command: ConnectCommand,
        declined: @escaping (SpclientError) -> Void = { _ in },
    ) {
        guard sendTransportCommand(
            name,
            promisesPosition: true,
            local: local,
            remote: { try await SpclientAPI().sendCommand(command, from: $0, to: $1) },
            declined: declined,
        ) else {
            return
        }

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
        // The client publishes the paused state; nothing is asserted here.
        sendTransportCommand(
            "pause()",
            local: { SpotifyPlayer.pause() },
            remote: { try await SpclientAPI().sendCommand(.pause, from: $0, to: $1) },
        )
    }

    func resume() {
        guard sendTransportCommand(
            "resume()",
            local: { try await SpotifyPlayer.resume() },
            remote: { try await SpclientAPI().sendCommand(.resume, from: $0, to: $1) },
        ) else {
            return
        }

        // Deliberately no syncPositionAnchor() here: the position we already hold is correct
        // from the paused state, since only the clock restarts. On the Rust path it was
        // worse than redundant — that player reported 0 for a moment after a resume, so
        // syncing would have thrown the position away.
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

    /// Whether Next goes anywhere; see `PlaybackState.canSkipNext`.
    var hasNext: Bool {
        shown?.canSkipNext ?? false
    }

    /// Whether shuffle may be switched on; see `PlaybackState.canShuffle`.
    var canShuffle: Bool {
        shown?.canShuffle ?? true
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
                debugLog("PlaybackViewModel", "Media command: play")
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
                debugLog("PlaybackViewModel", "Media command: pause")
                self.pauseFromMediaControls()
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                debugLog("PlaybackViewModel", "Media command: play/pause")
                if self.isPlaying {
                    self.pauseFromMediaControls()
                } else {
                    self.resume()
                }
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            debugLog("PlaybackViewModel", "Media command: next")
            next()
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            debugLog("PlaybackViewModel", "Media command: previous")
            previous()
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return }
                let positionMs = UInt32(seekEvent.positionTime * 1000)
                debugLog("PlaybackViewModel", "Media command: seek to \(positionMs)ms")
                self.seek(to: positionMs)
            }
            return .success
        }
    }

    // MARK: - System Sleep

    /// When the system last said it would sleep, until it says it woke.
    private var systemWillSleepAt: Date?

    /// How long after the system says it will sleep a pause is taken as the sleep's. Seen half
    /// a second after it; long enough for that, and short enough that a sleep which never
    /// happened, so never woke, does not silence the pause key for long.
    private nonisolated static let sleepPauseWindow: TimeInterval = 10

    /// For the life of the process, rather than a window's, whose observers would go with it
    /// when it closes.
    private func observeSystemSleep() {
        guard !SpotiflyApp.hostsUnitTests else { return }
        let center = NSWorkspace.shared.notificationCenter
        // On the main queue, so the mark is set before a command that follows it is handled.
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    private func systemWillSleep() {
        systemWillSleepAt = Date()
        debugLog("PlaybackViewModel", "System will sleep, disconnecting from Spotify")
        SpotifyPlayer.disconnect()
    }

    /// Reconnects rather than rebuilds; see `SpotifyPlayer.forceReconnect`. A rebuild that then
    /// failed would also leave nothing retrying.
    private func systemDidWake() {
        systemWillSleepAt = nil
        switch SpotifyPlayer.forceReconnect() {
        case .started, .alreadyRecovering:
            debugLog("PlaybackViewModel", "System wake detected, reconnect under way")
        case .noSession:
            // Never initialized, or signed out. Only the first wants a rebuild, and no recovery
            // is running for it to disturb.
            Task {
                guard await KeymasterSession.shared.hasGrant else {
                    debugLog("PlaybackViewModel", "System wake detected, signed out — nothing to reconnect")
                    return
                }
                debugLog("PlaybackViewModel", "System wake detected, no session — rebuilding")
                await forceReinitialize()
            }
        }
    }

    /// A pause from the media controls, unless it is the one macOS sends the now-playing app as
    /// the Mac goes to sleep while another device plays: `pause()` would send that on to the
    /// device, and the sleep stops nothing that plays elsewhere. This Mac's own playback still
    /// takes it; the sleep stops that audio anyway.
    private func pauseFromMediaControls() {
        guard isPlaying else { return }
        if Self.isSleepPause(willSleepAt: systemWillSleepAt, now: Date(), isActiveDevice: SpotifyPlayer.isActiveDevice) {
            debugLog("PlaybackViewModel", "Pause ignored: the Mac is going to sleep, and another device plays")
            return
        }
        pause()
    }

    /// Whether a pause is the sleep's: another device plays, and the system said it will sleep
    /// less than `sleepPauseWindow` ago and has not woken since.
    nonisolated static func isSleepPause(willSleepAt: Date?, now: Date, isActiveDevice: Bool) -> Bool {
        guard !isActiveDevice, let willSleepAt else { return false }
        return now.timeIntervalSince(willSleepAt) < sleepPauseWindow
    }

    /// Title published while no logical track resolves.
    ///
    /// The app claims the media controls at init by publishing a Now Playing entry, and
    /// that claim is only as good as the entry: removing the title outright leaves a
    /// nameless row in Control Center. Falling back to the app name keeps the claim
    /// intact between tracks, after logout, and while metadata is still loading.
    private static let unresolvedTrackTitle = "Spotifly"

    /// The id of the track the bar shows: the *logical* track, whose store entry owns the
    /// displayed metadata. The decoded audio item may be a relinked alternative with another id.
    var currentTrackId: String? {
        shown?.trackId
    }

    /// The store's entry for the track the bar shows, for the bar and Control Center alike; nil
    /// until its metadata has loaded.
    var currentTrack: Track? {
        currentTrackId.flatMap { store?.tracks[$0] }
    }

    /// The current track's length as the bar's scrubber and Control Center show it, or nil
    /// while none is known; see `displayedDuration(streamMs:storedMs:)`.
    var displayedDurationMs: UInt32? {
        Self.displayedDuration(streamMs: trackDurationMs, storedMs: currentTrack?.durationMs)
    }

    /// The stream's length, which is authoritative, or the store's until the stream has one: a
    /// new track starts without it (`handlePlaybackStateUpdate`), and the store's bridges that
    /// gap, so the first frames show a length. Nil while neither is known. The store is asked
    /// only then, as the scrubber reads this on each tick.
    nonisolated static func displayedDuration(streamMs: UInt32, storedMs: @autoclosure () -> Int?) -> UInt32? {
        if streamMs > 0 {
            return streamMs
        }
        guard let storedMs = storedMs(), let stored = playbackMilliseconds(Int64(storedMs)), stored > 0
        else { return nil }
        return stored
    }

    /// Writes duration, elapsed time, and playback rate into `info`.
    ///
    /// Duration and elapsed time move together: an elapsed time standing next to the
    /// *previous* track's duration is worse than no timing at all, so an unknown
    /// duration removes both keys rather than leaving one behind.
    private func applyNowPlayingTiming(to info: inout [String: Any]) {
        if let durationMs = displayedDurationMs {
            info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
            // Where the bar is now, not the anchor: macOS runs the elapsed time on from the
            // moment it is published, and an anchor can be seconds old by then, or back-dated
            // by a report's age.
            let validPosition = min(interpolatedPositionMs, durationMs)
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
    }

    /// Full Now Playing update — sets track metadata, duration, position, rate, and artwork.
    /// Call on: track start, next/prev, and when the queue's metadata arrives.
    func updateNowPlayingInfo() {
        let track = currentTrack

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let track {
            nowPlayingInfo[MPMediaItemPropertyTitle] = track.name
            nowPlayingInfo[MPMediaItemPropertyArtist] = track.artistName
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
        let artworkURL = track?.images.mediumURL
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
                    guard self.currentTrack?.images.mediumURL == url else { return }
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
    /// No title, artist, or artwork processing. Call on: seek, play/pause, drift correction, and
    /// every playback state update.
    ///
    /// Duration belongs here even though it is metadata: a new track starts without the stream
    /// duration, so a path that only wrote elapsed time would leave
    /// the previous track's duration standing against the new track's position.
    func updateNowPlayingPosition() {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        applyNowPlayingTiming(to: &nowPlayingInfo)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Player State

    /// Follows the connection, the playback state, the volume and the interruptions in the
    /// player model. Each observation gives the value as it stands, then every change, on the
    /// main actor.
    ///
    /// The playback state is how external control shows up: a phone pausing *this* device
    /// sends a Connect command over the dealer, which pauses the pipeline, whose state
    /// arrives here exactly as a local pause would.
    private func observePlayer() {
        Task { [weak self, player] in
            for await _ in Observations({ player.connection }) {
                self?.adoptConnectedSession()
            }
        }
        Task { [weak self, player] in
            for await state in Observations({ player.playback }) {
                self?.handlePlaybackStateUpdate(state)
            }
        }
        Task { [weak self, player] in
            for await volume in Observations({ player.volume }) {
                if let volume {
                    self?.handleVolumeChange(volume)
                }
            }
        }
        Task { [weak self, player] in
            for await interruption in Observations({ player.interruption }) {
                if let interruption {
                    self?.errorMessage = interruption.message
                }
            }
        }
    }

    /// Takes a session the client brought up on its own as this model's, rather than
    /// rebuilding it: a recovery after an explicit initialization failed. Reads the client
    /// itself, since the snapshot that says it is up can still be on its way.
    ///
    /// Do not clear `isInitialized` on a not-ready snapshot: a transient disconnect belongs
    /// to `LibrespotClient`'s auto-recovery, and clearing it would make the next user
    /// command start a destructive rebuild from here. An explicit initialization clears it
    /// itself before rebuilding.
    private func adoptConnectedSession() {
        syncConnectionReadiness()

        guard isConnectionReady,
              !isInitialized,
              !isLoggingOut,
              initializationTask == nil
        else {
            return
        }

        debugLog("PlaybackViewModel", "Adopting the session the client brought up on its own")
        isInitialized = true
        errorMessage = nil
    }

    /// Brings `isConnectionReady` in line with the client, freezing another device's position
    /// when it drops.
    ///
    /// Reads the live flags rather than trusting the delivered snapshot, which may already
    /// be stale by the time it arrives.
    ///
    /// Called on every connection change *and* once a second from the drift check.
    /// The second caller is deliberate: display interpolation now depends on this flag, so
    /// a single missed callback would leave the progress bar stopped during healthy
    /// playback — a more visible failure than the drift this prevents. Re-reading the flags
    /// on the timer makes that self-heal within a second, and routing both callers through
    /// here means the timer can never flip the flag without also freezing the position.
    private func syncConnectionReadiness() {
        let isReady = SpotifyPlayer.isSessionConnected
        guard isReady != isConnectionReady else { return }

        // Another device's position holds while the session is down.
        if !isReady, !SpotifyPlayer.isActiveDevice {
            freezePositionClock()
            debugLog("PlaybackViewModel", "Connection not ready, position frozen at \(positionAnchorMs)ms")
        }
        isConnectionReady = isReady
    }

    /// This Mac's logical Connect volume as the client published it: set here and echoed
    /// back, or changed from another device. Moves the slider without sending it back.
    private func handleVolumeChange(_ newVolume: Double) {
        debugLog("PlaybackViewModel", "Volume published: \(newVolume)")
        // The echo of a volume set here is no change.
        guard newVolume != volume else { return }
        // Set flag to prevent feedback loop
        isSettingVolumeLocally = true
        volume = newVolume
        isSettingVolumeLocally = false
        saveVolume()
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
            promisesPosition: true,
            local: { try await SpotifyPlayer.seek(positionMs: positionMs) },
            remote: { try await SpclientAPI().sendCommand(.seek(toMs: Int(positionMs)), from: $0, to: $1) },
        )

        // seek(to:) already moved the anchor so scrubbing feels immediate. If the command
        // could not be issued at all, re-sync from the real position instead of leaving the
        // UI parked at a position playback never reached.
        if !issued {
            syncPositionAnchor()
            updateNowPlayingPosition()
        }
    }

    /// Handle a playback state published by the client.
    private func handlePlaybackStateUpdate(_ state: PlaybackState?) {
        guard let state else {
            // Nothing plays here any more: a load failed, a context had nothing left to play,
            // another device took over, or the session went. The bar keeps the track, and the
            // clock stops where it had got to.
            if isPlaying {
                freezePositionClock()
                shown?.isPlaying = false
                updateNowPlayingPosition()
            }
            return
        }

        debugLog(
            "PlaybackViewModel",
            "Playback state update: playing=\(state.isPlaying), paused=\(state.isPaused), position=\(state.positionMs)ms, duration=\(state.durationMs)ms, shuffle=\(state.shuffle), uri=\(state.trackUri)",
        )

        // Every report names its track: the mirror skips a cluster's without one, and this
        // Mac's come from its queue. Track metadata (name, artist, etc.) comes from the queue.
        let trackChanged = state.trackUri != currentTrackUri
        // Connect snapshots carry these as signed 64-bit integers, so do not let a malformed
        // one turn a narrowing conversion into a process trap.
        let reportedDurationMs = Self.playbackMilliseconds(state.durationMs).flatMap { $0 > 0 ? $0 : nil }
        shown = ShownPlayback(
            trackUri: state.trackUri,
            trackId: SpotifyAPI.parseTrackURI(state.trackUri),
            isPlaying: state.isPlaying,
            durationMs: reportedDurationMs ?? (trackChanged ? 0 : trackDurationMs),
            shuffle: state.shuffle,
            canSkipNext: state.canSkipNext,
            canShuffle: state.canShuffle,
        )

        // Sync position anchor on state changes. When monitoring a remote device,
        // position_ms is the position at timestamp_ms, which can be minutes old.
        if let posMs = Self.playbackMilliseconds(state.positionMs) {
            let anchor = positionAnchor(forPosition: state.positionMs, takenAt: state.timestampMs)
            debugLog("PlaybackViewModel", "Position anchor: \(positionAnchorMs) -> \(posMs)\(anchor.logSuffix)")
            anchorPosition(posMs, at: anchor.time)
        } else {
            debugLog("PlaybackViewModel", "Ignoring out-of-range playback position: \(state.positionMs)ms")
        }

        // The anchor moved, so Control Center has to move with it: it runs on from the last
        // elapsed time published, and a seek on another device changes no rate and no track.
        if trackChanged {
            updateNowPlayingInfo()
        } else {
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

    // Anchor-based position tracking, timed by positionClockNow()
    // UI reads interpolatedPositionMs (computed)
    private var positionAnchorMs: UInt32 = 0
    private var positionAnchorTime: Double = PlaybackViewModel.positionClockNow()
    private var driftCorrectionTask: Task<Void, Never>?

    /// Now, in seconds, on the clock that every anchor time is read from and compared with.
    ///
    /// It has to count the time the Mac sleeps, as the wall clock does: a report's age is
    /// wall-clock time (`positionAnchor(forPosition:takenAt:)`), and another device plays on
    /// while this Mac sleeps. On Darwin, `CLOCK_MONOTONIC` is the wall-clock time since boot.
    nonisolated static func positionClockNow() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// How far the display may disagree with the player before the disagreement means something.
    private static let positionDisagreementMs: Int64 = 500

    /// How long an optimistic anchor is given to be confirmed before it is treated as a
    /// command that never happened. Long enough to cover the 150 ms seek debounce and the
    /// round trip after it — measured at ~25 ms from the seek to the state that answered it,
    /// on the Rust path — and it restarts on each drag update, so a long scrub extends it
    /// rather than outliving it.
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
    /// cluster state carrying a timestamp — passes that moment instead, so
    /// interpolation accounts for the delay rather than restarting the clock.
    ///
    /// `optimistic` marks the anchors that transport commands write ahead of playback, to
    /// keep scrubbing and skipping responsive. Those are promises rather than
    /// measurements, and `checkDriftAndSync` has to know the difference — so every other
    /// caller, all of which anchor something measured, clears the mark by writing.
    private func anchorPosition(
        _ positionMs: UInt32,
        at time: Double = PlaybackViewModel.positionClockNow(),
        optimistic: Bool = false,
    ) {
        positionAnchorMs = positionMs
        positionAnchorTime = time
        optimisticAnchorTime = optimistic ? Self.positionClockNow() : nil
    }

    /// Restarts interpolation at the position already held, without claiming to have
    /// measured it.
    ///
    /// Resume is the only caller: it moves neither the position nor its truth, just the
    /// clock. Going through `anchorPosition` instead would re-assign the position to
    /// itself and, worse, clear the optimistic mark — telling `checkDriftAndSync` that a
    /// seek made while paused had been confirmed, when resuming confirms nothing.
    private func restartPositionClock() {
        positionAnchorTime = Self.positionClockNow()
    }

    /// Pins the position where the clock had got to, before something that stops it, such as
    /// `isPlaying` turning false. Afterwards the display would fall back to the last anchor;
    /// see `positionRuns`.
    private func freezePositionClock() {
        anchorPosition(interpolatedPositionMs)
    }

    /// Computed position using anchor interpolation - UI should bind to this
    /// Read by the bar's TimelineView on each tick
    var interpolatedPositionMs: UInt32 {
        guard positionRuns else { return clampedToTrack(positionAnchorMs) }
        let elapsed = Self.positionClockNow() - positionAnchorTime
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
    /// construction the same length the display clamps against; its caller refreshes it from
    /// the same snapshot before anchoring. This guard used to live only on the Web API path,
    /// but staleness is a property of Spotify's timestamp, not of the endpoint that carried
    /// it — cluster updates forward `player_state.timestamp` unchanged and can be minutes
    /// old, while local callbacks stamp the current time and compensate by nothing.
    private func positionAnchor(forPosition positionMs: Int64, takenAt timestampMs: Int64) -> PositionAnchor {
        let now = Self.positionClockNow()
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
    /// The unknown case is what makes a track change safe; see `ShownPlayback.durationMs`.
    private func clampedToTrack(_ positionMs: UInt32) -> UInt32 {
        trackDurationMs > 0 ? min(positionMs, trackDurationMs) : positionMs
    }

    /// Runs the drift check once a second for the lifetime of the view model.
    ///
    /// Once a second, not every frame: the UI interpolates its own position through
    /// `TimelineView`, so this exists only to pull that clock back to the player's reality.
    private func startPositionTimer() {
        driftCorrectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                checkDriftAndSync()
            }
        }
    }

    /// Re-anchors at the local player's position, for a seek that could not be issued.
    private func syncPositionAnchor() {
        let playerPosition = SpotifyPlayer.positionMs
        // Don't overwrite a valid position with 0: the player says 0 while nothing is loaded
        // here, as after another device took playback.
        if playerPosition == 0, positionAnchorMs > 0 {
            debugLog("PlaybackViewModel", "syncPositionAnchor: skipping - playerPosition=0 but have valid anchor=\(positionAnchorMs)")
            return
        }
        debugLog("PlaybackViewModel", "syncPositionAnchor: playerPosition=\(playerPosition), was positionAnchorMs=\(positionAnchorMs)")
        anchorPosition(playerPosition)
    }

    /// Called every second to check for drift and sync state
    private func checkDriftAndSync() {
        // Readiness gates interpolation, so recover here from a callback that never arrived
        // rather than leaving the progress bar stopped until the next one does.
        syncConnectionReadiness()

        // Check for significant drift from the player's position - only when active device
        // Remote playback position is interpolated from cluster timestamp, not real-time.
        // A local track plays on through a reconnect, so this runs while disconnected too.
        guard isPlaying, SpotifyPlayer.isActiveDevice else { return }

        // Compare even when the reported value did not change: a frozen value is precisely
        // the signal that must pull a still-running Swift clock back to reality.
        //
        // The two directions are not the same measurement, so they do not share a
        // threshold:
        //
        // - **Display ahead of the player** means our clock kept running while playback
        //   stopped producing, which is the stall this check exists for. Half a second is
        //   plenty.
        // - **Display behind the player** is left alone. That gap used to be the render
        //   buffer: the Rust path reported where the *decoder* was, always in front of what
        //   was audible, and correcting to it jumped the bar forward into audio nobody had
        //   heard yet — the fight with the Spirc position that made the bar jitter through a
        //   context's first track. `AudioPipeline` reports the audible position now
        //   (`AudioRenderer.playedFrames`), so that buffer no longer sits between
        //   the two. The direction is still not corrected, which has not been re-measured
        //   against the new clock.
        //
        // The exception in both directions is an anchor a transport command wrote ahead of
        // playback. That is a promise, not a measurement, and the two disagree by design
        // until the command lands — so nothing can be judged inside the grace window. Past
        // it, an optimistic anchor that no measurement has confirmed is one playback never
        // carried out: `performSeek` rolls back a command it could not *issue*, and
        // `withdraw` one that failed, but a command that returned having done nothing — a
        // seek before there is a pipeline to reach — says so to nobody. Then either
        // direction is evidence, because the display is somewhere playback never went.
        let playerPosition = SpotifyPlayer.positionMs
        let displayedPosition = interpolatedPositionMs
        let displayedLead = Int64(displayedPosition) - Int64(playerPosition)

        let unconfirmedFor = optimisticAnchorTime.map { Self.positionClockNow() - $0 }
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
            debugLog("PlaybackViewModel", "Drift correction: \(displayedPosition) -> \(playerPosition)")
            anchorPosition(playerPosition)
            updateNowPlayingPosition()
        }
    }

    // MARK: - Favorite Management

    /// Toggles the current track's favorite status, for the now-playing bar's heart and the Like
    /// menu item (⌘L), which works without the bar.
    func toggleCurrentTrackFavorite() async {
        guard let trackId = currentTrackId, let trackService else { return }

        do {
            try await trackService.toggleFavorite(trackId: trackId)
        } catch {
            errorMessage = String(localized: "error.update_favorite \(error.localizedDescription)")
        }
    }

    // MARK: - Volume Persistence

    private func saveVolume() {
        UserDefaults.standard.set(volume, forKey: "playbackVolume")
    }

    /// This Mac's volume as it was last saved, or half when it never was.
    private static var savedVolume: Double {
        let saved = UserDefaults.standard.double(forKey: "playbackVolume")
        return saved > 0 ? saved : 0.5
    }

    /// Debounces the slider, so a drag does not flood Spirc or spclient with requests.
    private func setupVolumeDebounceSubscription() {
        // This Mac's, whether it plays, waits or is not up yet: the client keeps it, reports
        // it on Connect, and registers each session at it.
        volumeSubject
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] newVolume in
                SpotifyPlayer.setVolume(newVolume)
                self?.saveVolume()
            }
            .store(in: &volumeDebounceSubscriptions)
        remoteVolumeSubject
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] newVolume in
                guard let self, isInitialized, let route = connectRoute() else { return }
                let percent = Int((newVolume * 100).rounded())
                Task {
                    try? await SpclientAPI().setVolume(
                        percent: percent,
                        from: route.from,
                        to: route.to,
                    )
                }
            }
            .store(in: &volumeDebounceSubscriptions)
    }
}
