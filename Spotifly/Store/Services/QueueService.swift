//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue structure (track URIs) is received from Spirc via Mercury protocol.
//  Track metadata is fetched from Spotify Web API and cached in the store.
//

import Combine
import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let tokenProvider: () async -> String
    private var queueSubscription: AnyCancellable?
    private var metadataFetchTask: Task<Void, Never>?

    init(store: AppStore, tokenProvider: @escaping () async -> String) {
        self.store = store
        self.tokenProvider = tokenProvider
        setupQueueSubscription()
    }

    // MARK: - Queue Subscription

    /// Subscribe to queue updates from Spirc (via Mercury protocol)
    private func setupQueueSubscription() {
        queueSubscription = SpotifyPlayer.queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queueState in
                self?.handleQueueUpdate(queueState)
            }
    }

    /// Handle queue update from Spirc callback
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            store.setQueueItems([])
            store.currentIndex = 0
            return
        }

        // Build queue URIs list: previous + current + next
        var uris: [String] = []

        // Add previous tracks
        uris.append(contentsOf: state.previousTracks.map(\.uri))

        // Track the current index (after previous tracks)
        let currentIndex = uris.count

        // Add current track
        if let current = state.currentTrack {
            uris.append(current.uri)
        }

        // Add next tracks
        uris.append(contentsOf: state.nextTracks.map(\.uri))

        #if DEBUG
            print("[QueueService] Queue updated from Mercury: prev=\(state.previousTracks.count), current=\(state.currentTrack != nil ? 1 : 0), next=\(state.nextTracks.count), total=\(uris.count)")
        #endif

        // Store queue URIs and current index
        store.setQueueURIs(uris)
        store.currentIndex = state.currentTrack != nil ? currentIndex : 0

        // Fetch track metadata from Web API (uses store cache)
        fetchTrackMetadata(for: uris)
    }

    // MARK: - Metadata Fetching

    /// Fetch track metadata from Web API for tracks not already in the store
    private func fetchTrackMetadata(for uris: [String]) {
        // Cancel any pending fetch
        metadataFetchTask?.cancel()

        // Extract unique track IDs from URIs (queue can have duplicates)
        var seenIds = Set<String>()
        let uniqueTrackIds = uris.compactMap { uri -> String? in
            if uri.hasPrefix("spotify:track:") {
                let trackId = String(uri.dropFirst("spotify:track:".count))
                if seenIds.insert(trackId).inserted {
                    return trackId
                }
            }
            return nil
        }

        guard !uniqueTrackIds.isEmpty else { return }

        // Filter to only tracks not already in the store
        let trackIdsToFetch = uniqueTrackIds.filter { store.tracks[$0] == nil }

        guard !trackIdsToFetch.isEmpty else {
            #if DEBUG
                print("[QueueService] All \(uniqueTrackIds.count) unique tracks already cached in store")
            #endif
            // Update queue items from cached data
            updateQueueItemsFromStore()
            return
        }

        #if DEBUG
            print("[QueueService] Fetching \(trackIdsToFetch.count) tracks from Web API (\(uniqueTrackIds.count - trackIdsToFetch.count) cached)")
        #endif

        metadataFetchTask = Task { [weak self, tokenProvider] in
            guard let self else { return }

            do {
                let accessToken = await tokenProvider()
                let trackData = try await SpotifyAPI.fetchTracks(accessToken: accessToken, trackIds: trackIdsToFetch)

                guard !Task.isCancelled else { return }

                // Convert APITrack to Track and store in the global store
                var tracksToStore: [Track] = []
                for (trackId, apiTrack) in trackData {
                    let track = Track(
                        id: trackId,
                        name: apiTrack.name,
                        uri: apiTrack.uri,
                        durationMs: apiTrack.durationMs,
                        trackNumber: apiTrack.trackNumber,
                        externalUrl: apiTrack.externalUrl,
                        albumId: apiTrack.albumId,
                        artistId: apiTrack.artistId,
                        artistName: apiTrack.artistName,
                        albumName: apiTrack.albumName,
                        imageURL: apiTrack.imageURL,
                    )
                    tracksToStore.append(track)
                }

                // Store tracks in the global cache
                store.upsertTracks(tracksToStore)

                #if DEBUG
                    print("[QueueService] Cached \(tracksToStore.count) tracks in store")
                #endif

                // Update queue items from store
                updateQueueItemsFromStore()

            } catch {
                #if DEBUG
                    print("[QueueService] Failed to fetch track metadata: \(error)")
                #endif
            }
        }
    }

    /// Build queue items from cached track data in store
    private func updateQueueItemsFromStore() {
        let items: [QueueItem] = store.queueURIs.map { uri in
            // Extract track ID from URI
            if uri.hasPrefix("spotify:track:") {
                let trackId = String(uri.dropFirst("spotify:track:".count))
                if let track = store.tracks[trackId] {
                    return QueueItem(
                        id: uri,
                        uri: uri,
                        trackName: track.name,
                        artistName: track.artistName,
                        albumArtURL: track.imageURL?.absoluteString ?? "",
                        durationMs: UInt32(track.durationMs),
                        albumId: track.albumId,
                        artistId: track.artistId,
                        externalUrl: track.externalUrl,
                    )
                }
            }
            // Fallback for tracks not in store (shouldn't happen after fetch)
            return QueueItem(
                id: uri,
                uri: uri,
                trackName: "",
                artistName: "",
                albumArtURL: "",
                durationMs: 0,
                albumId: nil,
                artistId: nil,
                externalUrl: nil,
            )
        }

        store.setQueueItems(items)

        #if DEBUG
            let populated = items.count(where: { !$0.trackName.isEmpty })
            print("[QueueService] Queue items updated: \(populated)/\(items.count) with metadata")
        #endif
    }

    // MARK: - Favorites Loading

    /// Batch check favorite status for all queue items and store in AppStore
    func loadFavorites(accessToken: String) async {
        // Extract unique track IDs from URIs (queue can have duplicates)
        var seenIds = Set<String>()
        let trackIds = store.queueItems.compactMap { item -> String? in
            let uri = item.uri
            if uri.hasPrefix("spotify:track:") {
                let trackId = String(uri.dropFirst("spotify:track:".count))
                if seenIds.insert(trackId).inserted {
                    return trackId
                }
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
