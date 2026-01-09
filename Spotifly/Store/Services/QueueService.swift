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

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Queue Loading

    /// Load queue items from the Rust player
    func loadQueue() {
        store.queueErrorMessage = nil

        do {
            try store.setQueueItems(SpotifyPlayer.getAllQueueItems())
        } catch {
            store.queueErrorMessage = error.localizedDescription
        }
    }

    /// Refresh the queue
    func refresh() {
        loadQueue()
    }

    /// Batch check favorite status for all queue items and store in AppStore
    func loadFavorites(accessToken: String) async {
        // Extract track IDs from URIs
        let trackIds = store.queueItems.compactMap { item -> String? in
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

    // MARK: - Queue Manipulation

    /// Remove a track from the queue at the given index
    /// - Parameter index: Index of the track to remove (must be > currentIndex)
    func removeFromQueue(at index: Int) throws {
        try SpotifyPlayer.removeFromQueue(at: index)
        loadQueue() // Refresh queue from Rust
    }

    /// Move a track in the queue from one position to another
    /// - Parameters:
    ///   - from: Source index (must be > currentIndex)
    ///   - to: Destination index (must be > currentIndex)
    func moveQueueItem(from: Int, to: Int) throws {
        try SpotifyPlayer.moveQueueItem(from: from, to: to)
        loadQueue() // Refresh queue from Rust
    }

    /// Clear all unplayed tracks from the queue
    func clearUpcomingQueue() throws {
        try SpotifyPlayer.clearUpcomingQueue()
        loadQueue() // Refresh queue from Rust
    }
}
