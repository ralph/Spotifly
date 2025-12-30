//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

import MediaPlayer

@MainActor
@Observable
final class PlaybackViewModel {
    var isPlaying = false
    var isLoading = false
    var currentTrackId: String?
    var errorMessage: String?
    var queueLength: Int = 0
    var currentIndex: Int = 0

    // Track metadata for Now Playing
    var currentTrackName: String?
    var currentArtistName: String?
    var currentAlbumArtURL: String?
    var trackDurationMs: UInt32 = 0
    var currentPositionMs: UInt32 = 0

    private var isInitialized = false
    private var lastAlbumArtURL: String?
    var playbackStartTime: Date? // Internal for pause/resume handling
    private var positionTimer: Timer?

    init() {
        setupRemoteCommandCenter()

        // Set initial Now Playing info to claim media controls
        var initialInfo: [String: Any] = [:]
        initialInfo[MPMediaItemPropertyTitle] = "Spotifly"
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        // Start position update timer
        startPositionTimer()
    }

    // Timer will be automatically invalidated when the object is deallocated

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
            currentTrackId = uriOrUrl
            isPlaying = true
            playbackStartTime = Date()
            updateQueueState()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func playTrack(trackId: String, accessToken: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)", accessToken: accessToken)
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

            // Reset position tracking for new track
            currentPositionMs = 0
            if isPlaying {
                playbackStartTime = Date()
            }

            updateNowPlayingInfo()
        }
    }

    func next() {
        do {
            try SpotifyPlayer.next()
            isPlaying = true
            currentPositionMs = 0
            playbackStartTime = Date()
            updateQueueState()
            updateNowPlayingInfo()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previous() {
        do {
            try SpotifyPlayer.previous()
            isPlaying = true
            currentPositionMs = 0
            playbackStartTime = Date()
            updateQueueState()
            updateNowPlayingInfo()
        } catch {
            errorMessage = error.localizedDescription
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
                    // Adjust start time based on current position
                    if self.currentPositionMs > 0 {
                        self.playbackStartTime = Date().addingTimeInterval(-Double(self.currentPositionMs) / 1000.0)
                    } else {
                        self.playbackStartTime = Date()
                    }
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
                    self.playbackStartTime = nil
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
                    self.playbackStartTime = nil
                } else {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                    // Adjust start time based on current position
                    if self.currentPositionMs > 0 {
                        self.playbackStartTime = Date().addingTimeInterval(-Double(self.currentPositionMs) / 1000.0)
                    } else {
                        self.playbackStartTime = Date()
                    }
                }
                self.updateNowPlayingInfo()
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.previous()
            }
            return .success
        }

        // Seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return }

                let positionMs = UInt32(seekEvent.positionTime * 1000)

                do {
                    try SpotifyPlayer.seek(positionMs: positionMs)
                    self.currentPositionMs = positionMs

                    // Update playback start time to maintain sync
                    if self.isPlaying {
                        self.playbackStartTime = Date().addingTimeInterval(-Double(positionMs) / 1000.0)
                    }

                    self.updateNowPlayingInfo()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let trackName = currentTrackName {
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackName
        }

        if let artistName = currentArtistName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName
        }

        // Duration and position
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(trackDurationMs) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentPositionMs) / 1000.0
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

    private func startPositionTimer() {
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
            }
        }
    }

    private func updatePosition() {
        // Check if track changed (auto-advance)
        let rustCurrentIndex = SpotifyPlayer.currentIndex
        if rustCurrentIndex != currentIndex {
            // Track changed due to auto-advance
            currentIndex = rustCurrentIndex
            isPlaying = SpotifyPlayer.isPlaying
            playbackStartTime = isPlaying ? Date() : nil
            updateQueueState()
            return
        }

        // Sync playing state with Rust
        let rustIsPlaying = SpotifyPlayer.isPlaying
        if rustIsPlaying != isPlaying {
            isPlaying = rustIsPlaying
            if isPlaying {
                playbackStartTime = Date().addingTimeInterval(-Double(currentPositionMs) / 1000.0)
            } else {
                playbackStartTime = nil
            }
        }

        guard isPlaying, let startTime = playbackStartTime else {
            return
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let positionMs = UInt32(elapsed * 1000)

        // Clamp to duration
        currentPositionMs = min(positionMs, trackDurationMs)

        // Update Now Playing info periodically
        updateNowPlayingInfo()
    }
}
