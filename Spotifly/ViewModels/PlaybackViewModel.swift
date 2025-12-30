//
//  PlaybackViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class PlaybackViewModel {
    var isPlaying = false
    var isLoading = false
    var currentTrackId: String?
    var errorMessage: String?
    var queueLength: Int = 0
    var currentIndex: Int = 0
    private var isInitialized = false

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
    }

    func next() {
        do {
            try SpotifyPlayer.next()
            isPlaying = true
            updateQueueState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func previous() {
        do {
            try SpotifyPlayer.previous()
            isPlaying = true
            updateQueueState()
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
}
