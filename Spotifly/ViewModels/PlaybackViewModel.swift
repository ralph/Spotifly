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
                DispatchQueue.main.async {
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
    var currentTrackUri: String?
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

    private var isInitialized = false
    private var lastAlbumArtURL: String?
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

    private init() {
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
        initialInfo[MPMediaItemPropertyTitle] = "Spotifly"
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        // Start position update timer
        startPositionTimer()
    }

    /// Sets the token provider for automatic reinitialization after session disconnect.
    func setTokenProvider(_ provider: @escaping @Sendable () async -> String) {
        tokenProvider = provider
    }

    func forceReinitialize(accessToken: String) async {
        isInitialized = false
        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isInitialized = true
            for _ in 0 ..< 50 {
                if SpotifyPlayer.isSpircReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        // Reset stale playback state — after reinit Rust has no track/context loaded.
        // isPlaying must be false before updateNowPlayingPosition() so it writes rate=0.
        // updateNowPlayingPosition() must be called before zeroing trackDurationMs because
        // it guards on trackDurationMs > 0 and would silently no-op otherwise.
        isPlaying = false
        updateNowPlayingPosition()
        currentTrackUri = nil
        trackDurationMs = 0
        currentPositionMs = 0
        positionAnchorMs = 0
        positionAnchorTime = CACurrentMediaTime()
        isLoading = false
    }

    func initializeIfNeeded(accessToken: String) async {
        guard !isInitialized else { return }

        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isInitialized = true

            // Wait for Spirc to be ready (poll with timeout)
            for _ in 0 ..< 50 { // 5 seconds max
                if SpotifyPlayer.isSpircReady { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
        isPlaying = true
        // Apply volume after playback starts (mixer is now initialized)
        SpotifyPlayer.setVolume(volume)
        updateNowPlayingInfo()
        syncPositionAnchor()
        // Note: favorite status is checked by NowPlayingBarView's .task(id:) when currentTrackUri changes
    }

    func togglePlayPause(trackId: String, accessToken: String) async {
        if isPlaying, currentTrackUri == trackId {
            // Pause current track
            SpotifyPlayer.pause()
            isPlaying = false
        } else if !isPlaying, currentTrackUri == trackId {
            // Resume current track
            SpotifyPlayer.resume()
        } else {
            // Play new track
            await playTrack(trackId: trackId, accessToken: accessToken)
        }
    }

    func stop() {
        SpotifyPlayer.stop()
        isPlaying = false
        currentTrackUri = nil
    }

    /// Sets the AppStore reference. Call this after AppStore is created.
    func setStore(_ store: AppStore) {
        self.store = store
    }

    // MARK: - Playback Control (via Spirc or Web API)

    // Uses local Spirc when active device, Web API otherwise
    // State updates come back via Mercury callback

    func next() {
        if SpotifyPlayer.isActiveDevice {
            // During reconnection, session may not be fully connected yet
            guard SpotifyPlayer.isSessionConnected else {
                debugLog("PlaybackViewModel", "next() ignored - session not connected yet")
                return
            }
            SpotifyPlayer.next()
        } else {
            // Remote control via Web API
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.skipToNext(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        // Immediately reset position to 0 for responsive UI
        positionAnchorMs = 0
        positionAnchorTime = CACurrentMediaTime()
        currentPositionMs = 0
        updateNowPlayingInfo()
    }

    func previous() {
        if SpotifyPlayer.isActiveDevice {
            // During reconnection, session may not be fully connected yet
            guard SpotifyPlayer.isSessionConnected else {
                debugLog("PlaybackViewModel", "previous() ignored - session not connected yet")
                return
            }
            SpotifyPlayer.previous()
        } else {
            // Remote control via Web API
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.skipToPrevious(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
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
        if SpotifyPlayer.isActiveDevice {
            // During reconnection, session may not be fully connected yet
            guard SpotifyPlayer.isSessionConnected else {
                debugLog("PlaybackViewModel", "pause() ignored - session not connected yet")
                return
            }
            SpotifyPlayer.pause()
        } else {
            // Remote control via Web API
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.pausePlayback(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        // State update will come from Mercury callback
    }

    func resume() {
        if SpotifyPlayer.isActiveDevice {
            // During reconnection, session may not be fully connected yet
            guard SpotifyPlayer.isSessionConnected else {
                debugLog("PlaybackViewModel", "resume() ignored - session not connected yet")
                return
            }
            SpotifyPlayer.resume()
        } else {
            // Remote control via Web API
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.resumePlayback(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        // Don't call syncPositionAnchor() - Rust returns 0 immediately after resume
        // Keep the current positionAnchorMs (correct from paused state), just update the time
        positionAnchorTime = CACurrentMediaTime()
        updateNowPlayingPosition()
    }

    func toggleShuffle() {
        let targetShuffle = !isShuffleEnabled

        if SpotifyPlayer.isActiveDevice {
            guard SpotifyPlayer.isSessionConnected else {
                debugLog("PlaybackViewModel", "toggleShuffle() ignored - session not connected yet")
                return
            }
            SpotifyPlayer.setShuffle(targetShuffle)
        } else {
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.setShuffle(accessToken: token, enabled: targetShuffle)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
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

    /// Full Now Playing update — sets track metadata, duration, position, rate, and artwork.
    /// Call on: track start, next/prev, initial Web API load.
    func updateNowPlayingInfo() {
        // Don't update Now Playing with invalid data - causes --:-- display
        guard trackDurationMs > 0 else { return }

        // Read current track metadata from AppStore
        let currentTrack = store?.currentTrackEntity

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let trackName = currentTrack?.name {
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackName
        }

        if let artistName = currentTrack?.artistName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName
        }

        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(trackDurationMs) / 1000.0

        let validPosition = min(currentPositionMs, trackDurationMs)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // Album art - only download if URL changed
        if let url = currentTrack?.images.mediumURL, url.absoluteString != lastAlbumArtURL {
            lastAlbumArtURL = url.absoluteString

            // Download album art asynchronously
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let image = NSImage(data: data) else { return }

                    // Update Now Playing on main actor
                    await MainActor.run {
                        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        // Mark closure as @Sendable to fix crash - MPNowPlayingInfoCenter executes
                        // the closure on an internal dispatch queue, not on MainActor
                        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
                            image
                        }
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                } catch {
                    // Ignore album art download failures
                }
            }
        }
    }

    /// Lightweight Now Playing update — only writes elapsed time + playback rate.
    /// No metadata or artwork processing. Call on: seek, play/pause, drift correction.
    func updateNowPlayingPosition() {
        guard trackDurationMs > 0 else { return }
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let validPosition = min(currentPositionMs, trackDurationMs)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - Playback State Subscription

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
                if !notification.trackUri.isEmpty, notification.trackUri != currentTrackUri {
                    currentTrackUri = notification.trackUri
                    // Mark as playing since we're loading a new track
                    isPlaying = true
                }

                // Use position from loading callback - this is reliable
                if notification.positionMs > 0 {
                    let posMs = UInt32(notification.positionMs)
                    positionAnchorMs = posMs
                    positionAnchorTime = CACurrentMediaTime()
                    currentPositionMs = posMs
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
        if SpotifyPlayer.isActiveDevice {
            SpotifyPlayer.seek(positionMs: positionMs)
        } else {
            // Remote control via Web API
            Task {
                guard let token = await tokenProvider?() else { return }
                do {
                    try await SpotifyAPI.seekToPosition(accessToken: token, positionMs: Int(positionMs))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Handle playback state update from Spirc callback
    private func handlePlaybackStateUpdate(_ state: PlaybackState?) {
        guard let state else { return }

        debugLog(
            "PlaybackViewModel",
            "Playback state update: playing=\(state.isPlaying), paused=\(state.isPaused), position=\(state.positionMs)ms, duration=\(state.durationMs)ms, shuffle=\(state.shuffle), uri=\(state.trackUri)",
        )

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
        if !state.trackUri.isEmpty, state.trackUri != currentTrackUri {
            currentTrackUri = state.trackUri
            // Note: Track metadata (name, artist, etc.) will be updated from queue
        }

        // Update duration
        if state.durationMs > 0 {
            trackDurationMs = UInt32(state.durationMs)
        }

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

        // Update Now Playing position if playback rate changed
        if wasPlaying != isPlaying {
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
    private var lastRustPosition: UInt32 = 0
    private var driftCorrectionTimer: DriftCorrectionTimer?
    private var driftObserver: NSObjectProtocol?

    /// Computed position using anchor interpolation - UI should bind to this
    /// Called by TimelineView on every frame for smooth updates
    var interpolatedPositionMs: UInt32 {
        guard isPlaying else { return currentPositionMs }
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
        lastRustPosition = rustPosition
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

        // Skip position updates while paused - position only changes during playback
        guard isPlaying else { return }

        // Check for significant drift from Rust position - only when active device
        // Remote playback position is interpolated from cluster timestamp, not real-time
        if SpotifyPlayer.isActiveDevice {
            let rustPosition = SpotifyPlayer.positionMs
            if rustPosition != lastRustPosition {
                let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
                if drift > 500 {
                    positionAnchorMs = rustPosition
                    positionAnchorTime = CACurrentMediaTime()
                    currentPositionMs = min(rustPosition, trackDurationMs)
                    didCorrectDrift = true
                }
                lastRustPosition = rustPosition
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
