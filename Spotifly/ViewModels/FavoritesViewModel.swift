//
//  FavoritesViewModel.swift
//  Spotifly
//
//  Manages user's saved tracks (favorites) state and loading
//

import SwiftUI

@MainActor
@Observable
final class FavoritesViewModel {
    var tracks: [SavedTrack] = []
    var isLoading = false
    var errorMessage: String?
    var hasMore = false
    private var currentOffset = 0
    private var totalTracks = 0

    func loadTracks(accessToken: String) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserSavedTracks(
                accessToken: accessToken,
                limit: 50,
                offset: 0,
            )

            tracks = response.tracks
            totalTracks = response.total
            hasMore = response.hasMore
            currentOffset = response.nextOffset ?? 0
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreIfNeeded(accessToken: String) async {
        guard hasMore, !isLoading else { return }

        isLoading = true

        do {
            let response = try await SpotifyAPI.fetchUserSavedTracks(
                accessToken: accessToken,
                limit: 50,
                offset: currentOffset,
            )

            tracks.append(contentsOf: response.tracks)
            hasMore = response.hasMore
            currentOffset = response.nextOffset ?? currentOffset
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refresh(accessToken: String) async {
        currentOffset = 0
        hasMore = false
        await loadTracks(accessToken: accessToken)
    }

    func unfavoriteTrack(trackId: String, accessToken: String) async {
        do {
            try await SpotifyAPI.removeSavedTrack(accessToken: accessToken, trackId: trackId)

            // Remove the track from the local list
            tracks.removeAll { $0.id == trackId }
            totalTracks -= 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes a track from the local list (used when TrackRow handles the API call)
    func removeTrack(id: String) {
        tracks.removeAll { $0.id == id }
        totalTracks -= 1
    }
}
