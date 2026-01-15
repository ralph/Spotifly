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

    /// Handle queue update from Spirc callback or Web API
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            store.setQueue(previous: [], current: nil, next: [])
            return
        }

        // Extract URIs from queue state
        let currentURI = state.currentTrack?.uri
        let nextURIs = state.nextTracks.map(\.uri)
        // previousTracks is nil when from Web API (which doesn't provide history)
        let previousURIs = state.previousTracks?.map(\.uri)

        #if DEBUG
            if let prevCount = previousURIs?.count {
                print("[QueueService] Queue updated from Mercury: prev=\(prevCount), current=\(currentURI != nil ? 1 : 0), next=\(nextURIs.count)")
            } else {
                print("[QueueService] Queue updated from Web API: current=\(currentURI != nil ? 1 : 0), next=\(nextURIs.count) (preserving previous)")
            }
        #endif

        store.setQueue(previous: previousURIs, current: currentURI, next: nextURIs)

        // Fetch track metadata (uses store cache)
        let allURIs = (previousURIs ?? []) + (currentURI.map { [$0] } ?? []) + nextURIs
        fetchTrackMetadata(for: allURIs)
    }

    // MARK: - Metadata Fetching

    /// Fetch track metadata from Web API for tracks not already in the store
    private func fetchTrackMetadata(for uris: [String]) {
        // Cancel any pending fetch
        metadataFetchTask?.cancel()

        // Extract unique track IDs from URIs (queue can have duplicates)
        var seenIds = Set<String>()
        let uniqueTrackIds = uris.compactMap { uri -> String? in
            guard let trackId = SpotifyAPI.parseTrackURI(uri),
                  seenIds.insert(trackId).inserted
            else { return nil }
            return trackId
        }

        guard !uniqueTrackIds.isEmpty else { return }

        // Filter to only tracks not already in the store
        let trackIdsToFetch = uniqueTrackIds.filter { store.tracks[$0] == nil }

        guard !trackIdsToFetch.isEmpty else {
            #if DEBUG
                print("[QueueService] All \(uniqueTrackIds.count) unique tracks already cached in store")
            #endif
            // Update queue items from cached data
            updateNowPlayingMetadata()
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
                updateNowPlayingMetadata()

            } catch {
                #if DEBUG
                    print("[QueueService] Failed to fetch track metadata: \(error)")
                #endif
            }
        }
    }

    /// Update PlaybackViewModel with current track metadata for Now Playing info
    private func updateNowPlayingMetadata() {
        // Use computed property to get current track from store
        if let track = store.currentTrack {
            PlaybackViewModel.shared.setCurrentTrackMetadata(
                name: track.name,
                artist: track.artistName,
                artURL: track.imageURL?.absoluteString,
            )
        }

        #if DEBUG
            let prevCount = store.previousTracks.count
            let nextCount = store.nextTracks.count
            let total = prevCount + (store.currentTrack != nil ? 1 : 0) + nextCount
            print("[QueueService] Queue tracks resolved: \(total) with metadata (prev=\(prevCount), next=\(nextCount))")
        #endif
    }

    // MARK: - Favorites Loading

    /// Batch check favorite status for all queue tracks and store in AppStore
    func loadFavorites(accessToken: String) async {
        // Collect all queue URIs
        var allURIs = store.previousTrackURIs
        if let current = store.currentTrackURI {
            allURIs.append(current)
        }
        allURIs.append(contentsOf: store.nextTrackURIs)

        // Extract unique track IDs from URIs (queue can have duplicates)
        var seenIds = Set<String>()
        let trackIds = allURIs.compactMap { uri -> String? in
            guard let trackId = SpotifyAPI.parseTrackURI(uri),
                  seenIds.insert(trackId).inserted
            else { return nil }
            return trackId
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
