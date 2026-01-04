//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import QuartzCore
import SwiftUI

import MediaPlayer

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

    var isPlaying = false
    var isLoading = false
    var currentTrackId: String?
    var errorMessage: String?
    var queueLength: Int = 0
    var currentIndex: Int = 0

    // Spotify Connect state
    var isSpotifyConnectActive = false
    var spotifyConnectDeviceId: String?
    var spotifyConnectDeviceName: String?
    private var spotifyConnectAccessToken: String?
    private var spotifyConnectSyncTask: Task<Void, Never>?

    // Spotify Connect queue (from Web API)
    var spotifyConnectQueue: [QueueTrack] = []

    // Spotify Connect volume (0-100)
    var spotifyConnectVolume: Double = 50
    private var volumeUpdateTask: Task<Void, Never>?

    /// Returns the URI of the currently playing track
    var currentlyPlayingURI: String? {
        // Try to get URI from queue first, fallback to currentTrackId for single tracks
        SpotifyPlayer.queueUri(at: currentIndex) ?? currentTrackId
    }

    // Track metadata for Now Playing
    var currentTrackName: String?
    var currentArtistName: String?
    var currentAlbumArtURL: String?
    var trackDurationMs: UInt32 = 0
    var currentPositionMs: UInt32 = 0

    // Volume (0.0 - 1.0)
    var volume: Double = 0.5 {
        didSet {
            // Only apply volume if player is initialized (mixer is ready)
            if isInitialized {
                SpotifyPlayer.setVolume(volume)
            }
            saveVolume()
        }
    }

    // Favorite status of currently playing track
    var isCurrentTrackFavorited = false

    private var isInitialized = false
    private var lastAlbumArtURL: String?

    private init() {
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

    func initializeIfNeeded(accessToken: String) async {
        guard !isInitialized else { return }

        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isInitialized = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func play(uriOrUrl: String, accessToken: String) async {
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
            try await SpotifyPlayer.play(uriOrUrl: uriOrUrl)
            await handlePlaybackStarted(trackId: uriOrUrl, accessToken: accessToken)
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
            await handlePlaybackStarted(trackId: trackUris[0], accessToken: accessToken)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addToQueue(trackUri: String, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        errorMessage = nil

        do {
            try await SpotifyPlayer.addToQueue(trackUri: trackUri)
            // Update queue state to reflect the change
            updateQueueState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func playNext(trackUri: String, accessToken: String) async {
        // Initialize if needed
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        guard isInitialized else {
            errorMessage = "Player not initialized"
            return
        }

        errorMessage = nil

        do {
            try await SpotifyPlayer.addNextToQueue(trackUri: trackUri)
            // Update queue state to reflect the change
            updateQueueState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playback State Helpers

    /// Common setup after playback has started
    private func handlePlaybackStarted(trackId: String, accessToken: String) async {
        currentTrackId = trackId
        isPlaying = true
        // Apply volume after playback starts (mixer is now initialized)
        SpotifyPlayer.setVolume(volume)
        updateQueueState()
        syncPositionAnchor()
        await checkCurrentTrackFavoriteStatus(accessToken: accessToken)
    }

    func togglePlayPause(trackId: String, accessToken: String) async {
        if isPlaying, currentTrackId == trackId {
            // Pause current track
            SpotifyPlayer.pause()
            isPlaying = false
        } else if !isPlaying, currentTrackId == trackId {
            // Resume current track
            SpotifyPlayer.resume()
            isPlaying = true
        } else {
            // Play new track
            await playTrack(trackId: trackId, accessToken: accessToken)
        }
    }

    func stop() {
        SpotifyPlayer.stop()
        isPlaying = false
        currentTrackId = nil
    }

    func updatePlayingState() {
        isPlaying = SpotifyPlayer.isPlaying
    }

    func updateQueueState() {
        queueLength = SpotifyPlayer.queueLength
        currentIndex = SpotifyPlayer.currentIndex

        // Update current track metadata
        if queueLength > 0, currentIndex < queueLength {
            currentTrackName = SpotifyPlayer.queueTrackName(at: currentIndex)
            currentArtistName = SpotifyPlayer.queueArtistName(at: currentIndex)
            currentAlbumArtURL = SpotifyPlayer.queueAlbumArtUrl(at: currentIndex)
            trackDurationMs = SpotifyPlayer.queueDurationMs(at: currentIndex)
            // Position is synced separately via syncPositionAnchor()
            updateNowPlayingInfo()
        }
    }

    func next() {
        if isSpotifyConnectActive, let token = spotifyConnectAccessToken {
            Task {
                do {
                    try await SpotifyAPI.skipToNext(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            do {
                try SpotifyPlayer.next()
                isPlaying = true
                updateQueueState()
                syncPositionAnchor()
                updateNowPlayingInfo()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func previous() {
        if isSpotifyConnectActive, let token = spotifyConnectAccessToken {
            Task {
                do {
                    try await SpotifyAPI.skipToPrevious(accessToken: token)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            do {
                try SpotifyPlayer.previous()
                isPlaying = true
                updateQueueState()
                syncPositionAnchor()
                updateNowPlayingInfo()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func seek(to positionMs: UInt32) {
        if isSpotifyConnectActive, let token = spotifyConnectAccessToken {
            Task {
                do {
                    try await SpotifyAPI.seekToPosition(accessToken: token, positionMs: Int(positionMs))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            do {
                try SpotifyPlayer.seek(positionMs: positionMs)
                // Update anchor for smooth interpolation from new position
                positionAnchorMs = positionMs
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = positionMs
                updateNowPlayingInfo()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Spotify Connect

    /// Activates Spotify Connect mode - playback controls will use Web API
    func activateSpotifyConnect(deviceId: String, deviceName: String? = nil, accessToken: String) {
        isSpotifyConnectActive = true
        spotifyConnectDeviceId = deviceId
        spotifyConnectDeviceName = deviceName
        spotifyConnectAccessToken = accessToken

        // Pause local playback
        SpotifyPlayer.pause()

        // Start periodic sync
        startSpotifyConnectSync()
    }

    /// Deactivates Spotify Connect mode - returns to local playback
    func deactivateSpotifyConnect() {
        isSpotifyConnectActive = false
        spotifyConnectDeviceId = nil
        spotifyConnectDeviceName = nil
        spotifyConnectQueue = []

        // Stop sync task
        spotifyConnectSyncTask?.cancel()
        spotifyConnectSyncTask = nil
    }

    /// Check if there's active remote playback and sync state
    func checkAndSyncRemotePlayback(accessToken: String) async {
        do {
            guard let playbackState = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken) else {
                // No active playback
                if isSpotifyConnectActive {
                    deactivateSpotifyConnect()
                }
                return
            }

            // Check if playback is on a remote device (not this app)
            if let device = playbackState.device {
                // If playing on a different device, activate Spotify Connect mode
                let isRemoteDevice = !device.name.contains("Spotifly")

                if isRemoteDevice && playbackState.isPlaying {
                    // Activate Spotify Connect mode for the remote device
                    if !isSpotifyConnectActive || spotifyConnectDeviceId != device.id {
                        isSpotifyConnectActive = true
                        spotifyConnectDeviceId = device.id
                        spotifyConnectDeviceName = device.name
                        spotifyConnectAccessToken = accessToken
                    }

                    // Sync volume
                    if let volumePercent = device.volumePercent {
                        spotifyConnectVolume = Double(volumePercent)
                    }

                    // Update playback state
                    isPlaying = playbackState.isPlaying
                    if let track = playbackState.currentTrack {
                        currentTrackId = track.uri
                        currentTrackName = track.name
                        currentArtistName = track.artistName
                        currentAlbumArtURL = track.imageURL?.absoluteString
                        trackDurationMs = UInt32(track.durationMs)
                        currentPositionMs = UInt32(playbackState.progressMs)
                        positionAnchorMs = UInt32(playbackState.progressMs)
                        positionAnchorTime = CACurrentMediaTime()
                    }

                    // Fetch queue
                    await syncSpotifyConnectQueue(accessToken: accessToken)

                    // Start sync if not already running
                    if spotifyConnectSyncTask == nil {
                        startSpotifyConnectSync()
                    }

                    updateNowPlayingInfo()
                } else if !isRemoteDevice || !playbackState.isPlaying {
                    // Playback stopped or transferred to this device
                    if isSpotifyConnectActive, !playbackState.isPlaying {
                        isPlaying = false
                        updateNowPlayingInfo()
                    }
                }
            }
        } catch {
            // Silently handle errors during sync
        }
    }

    /// Sync queue from Spotify Connect
    private func syncSpotifyConnectQueue(accessToken: String) async {
        do {
            let queueResponse = try await SpotifyAPI.fetchQueue(accessToken: accessToken)
            spotifyConnectQueue = queueResponse.queue
            queueLength = queueResponse.queue.count + (queueResponse.currentlyPlaying != nil ? 1 : 0)
        } catch {
            // Silently handle queue fetch errors
        }
    }

    /// Start periodic sync for Spotify Connect state
    private func startSpotifyConnectSync() {
        spotifyConnectSyncTask?.cancel()

        spotifyConnectSyncTask = Task {
            while !Task.isCancelled, isSpotifyConnectActive {
                guard let token = spotifyConnectAccessToken else { break }

                await syncSpotifyConnectState(accessToken: token)

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Sync current playback state from Spotify Connect
    private func syncSpotifyConnectState(accessToken: String) async {
        do {
            guard let playbackState = try await SpotifyAPI.fetchPlaybackState(accessToken: accessToken) else {
                // Playback stopped
                isPlaying = false
                updateNowPlayingInfo()
                return
            }

            // Update playing state
            let wasPlaying = isPlaying
            isPlaying = playbackState.isPlaying

            // Update track info if changed
            if let track = playbackState.currentTrack {
                let trackChanged = currentTrackId != track.uri

                currentTrackId = track.uri
                currentTrackName = track.name
                currentArtistName = track.artistName
                currentAlbumArtURL = track.imageURL?.absoluteString
                trackDurationMs = UInt32(track.durationMs)

                // Update position
                currentPositionMs = UInt32(playbackState.progressMs)
                if isPlaying {
                    positionAnchorMs = UInt32(playbackState.progressMs)
                    positionAnchorTime = CACurrentMediaTime()
                }

                // Refresh queue if track changed
                if trackChanged {
                    await syncSpotifyConnectQueue(accessToken: accessToken)
                }
            }

            // Update device info and volume
            if let device = playbackState.device {
                spotifyConnectDeviceId = device.id
                spotifyConnectDeviceName = device.name
                if let volumePercent = device.volumePercent {
                    spotifyConnectVolume = Double(volumePercent)
                }
            }

            if wasPlaying != isPlaying || playbackState.currentTrack != nil {
                updateNowPlayingInfo()
            }
        } catch {
            // Silently handle sync errors
        }
    }

    /// Pause playback (works for both local and Spotify Connect)
    func pause() {
        if isSpotifyConnectActive, let token = spotifyConnectAccessToken {
            Task {
                do {
                    try await SpotifyAPI.pausePlayback(accessToken: token)
                    isPlaying = false
                    updateNowPlayingInfo()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            SpotifyPlayer.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }
    }

    /// Resume playback (works for both local and Spotify Connect)
    func resume() {
        if isSpotifyConnectActive, let token = spotifyConnectAccessToken {
            Task {
                do {
                    try await SpotifyAPI.resumePlayback(accessToken: token)
                    isPlaying = true
                    updateNowPlayingInfo()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            SpotifyPlayer.resume()
            isPlaying = true
            updateNowPlayingInfo()
        }
    }

    /// Set volume for Spotify Connect device (debounced)
    func setSpotifyConnectVolume(_ volume: Double) {
        spotifyConnectVolume = volume

        // Cancel any pending volume update
        volumeUpdateTask?.cancel()

        // Debounce volume updates
        volumeUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let token = spotifyConnectAccessToken else { return }

            do {
                try await SpotifyAPI.setVolume(accessToken: token, volumePercent: Int(volume))
            } catch {
                // Silently ignore volume errors
            }
        }
    }

    func getQueueTrackName(at index: Int) -> String? {
        SpotifyPlayer.queueTrackName(at: index)
    }

    func getQueueArtistName(at index: Int) -> String? {
        SpotifyPlayer.queueArtistName(at: index)
    }

    var hasNext: Bool {
        currentIndex + 1 < queueLength
    }

    var hasPrevious: Bool {
        currentIndex > 0
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
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                } else {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                }
                self.updateNowPlayingInfo()
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

    func updateNowPlayingInfo() {
        // Don't update Now Playing with invalid data - causes --:-- display
        guard trackDurationMs > 0 else { return }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let trackName = currentTrackName {
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackName
        }

        if let artistName = currentArtistName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName
        }

        // Duration and position - ensure position doesn't exceed duration
        let validPosition = min(currentPositionMs, trackDurationMs)
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(trackDurationMs) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Update Now Playing (preserves existing artwork)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // Album art - only download if URL changed
        if let artURL = currentAlbumArtURL, artURL != lastAlbumArtURL, !artURL.isEmpty, let url = URL(string: artURL) {
            lastAlbumArtURL = artURL

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
        guard trackDurationMs > 0 else { return 0 }

        let elapsed = CACurrentMediaTime() - positionAnchorTime
        let elapsedMs = UInt32(max(0, min(elapsed * 1000, Double(UInt32.max - 1))))
        let interpolated = positionAnchorMs.addingReportingOverflow(elapsedMs).partialValue
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
        positionAnchorMs = rustPosition
        positionAnchorTime = CACurrentMediaTime()
        lastRustPosition = rustPosition
        currentPositionMs = rustPosition
    }

    /// Called every second to check for drift and sync state
    private func checkDriftAndSync() {
        // Skip Rust-based sync when Spotify Connect is active
        // (Spotify Connect uses its own sync via syncSpotifyConnectState)
        guard !isSpotifyConnectActive else {
            // Just update currentPositionMs for non-TimelineView consumers
            currentPositionMs = interpolatedPositionMs
            updateNowPlayingInfo()
            return
        }

        // Check if track changed (auto-advance)
        let rustCurrentIndex = SpotifyPlayer.currentIndex
        if rustCurrentIndex != currentIndex {
            currentIndex = rustCurrentIndex
            isPlaying = SpotifyPlayer.isPlaying
            updateQueueState()
            syncPositionAnchor()
            return
        }

        // Sync playing state with Rust
        let rustIsPlaying = SpotifyPlayer.isPlaying
        if rustIsPlaying != isPlaying {
            isPlaying = rustIsPlaying
            syncPositionAnchor()
        }

        // Update currentPositionMs for non-TimelineView consumers
        currentPositionMs = interpolatedPositionMs

        // Check for significant drift from Rust position
        let rustPosition = SpotifyPlayer.positionMs
        if rustPosition != lastRustPosition {
            let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
            if drift > 500 {
                // More than 500ms drift - resync anchor
                positionAnchorMs = rustPosition
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = min(rustPosition, trackDurationMs)
            }
            lastRustPosition = rustPosition
        }

        updateNowPlayingInfo()
    }

    // MARK: - Favorite Management

    func checkCurrentTrackFavoriteStatus(accessToken: String) async {
        guard let trackId = extractTrackId(from: currentTrackId) else {
            isCurrentTrackFavorited = false
            return
        }

        do {
            isCurrentTrackFavorited = try await SpotifyAPI.checkSavedTrack(
                accessToken: accessToken,
                trackId: trackId,
            )
        } catch {
            print("Error checking favorite status: \(error)")
            isCurrentTrackFavorited = false
        }
    }

    func toggleCurrentTrackFavorite(accessToken: String) async {
        guard let trackId = extractTrackId(from: currentTrackId) else {
            return
        }

        do {
            if isCurrentTrackFavorited {
                try await SpotifyAPI.removeSavedTrack(accessToken: accessToken, trackId: trackId)
                isCurrentTrackFavorited = false
            } else {
                try await SpotifyAPI.saveTrack(accessToken: accessToken, trackId: trackId)
                isCurrentTrackFavorited = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractTrackId(from uri: String?) -> String? {
        guard let uri else { return nil }

        // URI format: spotify:track:TRACK_ID
        let components = uri.split(separator: ":")
        guard components.count >= 3, components[0] == "spotify", components[1] == "track" else {
            return nil
        }

        return String(components[2])
    }

    // MARK: - Volume Persistence

    private func saveVolume() {
        UserDefaults.standard.set(volume, forKey: "playbackVolume")
    }
}
