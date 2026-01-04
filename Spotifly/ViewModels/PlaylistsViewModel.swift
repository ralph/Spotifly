//
//  PlaylistsViewModel.swift
//  Spotifly
//
//  Manages user's playlists state and loading
//

import SwiftUI

@MainActor
@Observable
final class PlaylistsViewModel {
    var playlists: [PlaylistSimplified] = []
    var isLoading = false
    var errorMessage: String?
    var hasMore = false
    private var currentOffset = 0
    private var totalPlaylists = 0

    func loadPlaylists(accessToken: String) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserPlaylists(
                accessToken: accessToken,
                limit: 50,
                offset: 0,
            )

            playlists = response.playlists
            totalPlaylists = response.total
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
            let response = try await SpotifyAPI.fetchUserPlaylists(
                accessToken: accessToken,
                limit: 50,
                offset: currentOffset,
            )

            playlists.append(contentsOf: response.playlists)
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
        await loadPlaylists(accessToken: accessToken)
    }

    /// Update the track count for a playlist (for immediate UI feedback)
    func updateTrackCount(playlistId: String, count: Int) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].trackCount = count
        }
    }

    /// Increment the track count for a playlist
    func incrementTrackCount(playlistId: String, by count: Int = 1) {
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            playlists[index].trackCount += count
        }
    }
}
