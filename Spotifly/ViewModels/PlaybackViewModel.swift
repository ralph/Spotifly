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

    func playTrack(trackId: String, accessToken: String) async {
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
            try await SpotifyPlayer.playTrack(trackId: trackId)
            currentTrackId = trackId
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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
}
