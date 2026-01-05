//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue data comes from SpotifyPlayer (Rust), favorites are managed via TrackService.
//

import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore

    var queueItems: [QueueItem] = []
    var errorMessage: String?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Queue Loading

    /// Load queue items from the Rust player
    func loadQueue() {
        errorMessage = nil

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh the queue
    func refresh() {
        loadQueue()
    }

    /// Batch check favorite status for all queue items and store in AppStore
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
            let statuses = try await SpotifyAPI.checkSavedTracks(
                accessToken: accessToken,
                trackIds: trackIds,
            )
            store.updateFavoriteStatuses(statuses)
        } catch {
            // Silently fail - favorites just won't show
        }
    }
}
