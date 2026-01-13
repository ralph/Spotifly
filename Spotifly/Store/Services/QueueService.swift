//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue data is fetched from Spotify Web API (works for all devices).
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

    /// Load queue from Spotify Web API
    func loadConnectQueue(accessToken: String) async {
        store.queueErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchQueue(accessToken: accessToken)

            #if DEBUG
                print("[QueueService] Queue: currentlyPlaying=\(response.currentlyPlaying?.name ?? "nil"), queue count=\(response.queue.count)")
            #endif

            // Build queue items: currently playing + queue
            let currentItems = response.currentlyPlaying.map { [QueueItem(from: $0)] } ?? []
            let queueItems = response.queue.map { QueueItem(from: $0) }
            store.setQueueItems(currentItems + queueItems)

            // Current index is always 0 (currently playing is first)
            store.currentIndex = 0
        } catch {
            store.queueErrorMessage = error.localizedDescription
        }
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
}
