//
//  QueueViewModel.swift
//  Spotifly
//
//  Manages current playback queue state
//

import SwiftUI

@MainActor
@Observable
final class QueueViewModel {
    var queueItems: [QueueItem] = []
    var favoriteStatus: [String: Bool] = [:]
    var errorMessage: String?

    func loadQueue() {
        errorMessage = nil

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Batch fetch favorite status for all queue items
    func loadFavorites(accessToken: String) async {
        // Extract track IDs from URIs
        let trackIds = queueItems.compactMap { item -> String? in
            let uri = item.uri
            if uri.hasPrefix("spotify:track:") {
                return String(uri.dropFirst("spotify:track:".count))
            }
            return nil
        }

        guard !trackIds.isEmpty else { return }

        do {
            favoriteStatus = try await SpotifyAPI.checkSavedTracks(
                accessToken: accessToken,
                trackIds: trackIds,
            )
        } catch {
            // Silently fail - favorites just won't show
        }
    }

    /// Check if a track is favorited (by track ID)
    func isFavorited(trackId: String) -> Bool {
        favoriteStatus[trackId] ?? false
    }

    /// Update favorite status locally (after toggle)
    func setFavorited(trackId: String, value: Bool) {
        favoriteStatus[trackId] = value
    }

    func refresh() {
        loadQueue()
    }
}
