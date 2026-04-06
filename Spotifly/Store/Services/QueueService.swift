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
    private var setQueueSubscription: AnyCancellable?
    private var metadataFetchTask: Task<Void, Never>?
    private var pendingQueueRefreshTask: Task<Void, Never>?
    private var pendingTrackIds: Set<String> = []
    /// Subject for debouncing metadata fetch requests
    private let fetchSubject = PassthroughSubject<Void, Never>()
    /// Subscription for debounced fetch operations
    private var fetchDebounceSubscription: AnyCancellable?

    init(store: AppStore, tokenProvider: @escaping () async -> String) {
        self.store = store
        self.tokenProvider = tokenProvider
        setupQueueSubscription()
        setupSetQueueSubscription()
        setupFetchDebounceSubscription()
    }

    // MARK: - Queue Subscriptions

    /// Subscribe to queue updates from Spirc (via Mercury protocol)
    /// This fires after round-trip to Spotify servers
    private func setupQueueSubscription() {
        queueSubscription = SpotifyPlayer.queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queueState in
                self?.handleQueueUpdate(queueState)
            }
    }

    /// Subscribe to set queue events from Spirc
    /// This fires immediately when the queue is set/modified (e.g., from mobile app)
    private func setupSetQueueSubscription() {
        setQueueSubscription = SpotifyPlayer.setQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSetQueue(notification)
            }
    }

    /// Handle set queue notification (fires immediately when queue is set or context is loaded)
    private func handleSetQueue(_ notification: SetQueueNotification) {
        let contextInfo = notification.contextUri.isEmpty ? "" : " context=\(notification.contextUri),"
        debugLog("QueueService", "Set queue:\(contextInfo) prev=\(notification.prevTracks.count), current=\(notification.currentTrack != nil ? 1 : 0), next=\(notification.nextTracks.count)")

        // A SetQueue with a context URI but no tracks is provisional: librespot emits it during
        // context setup before fill_up_next_tracks completes. Keep the existing queue and schedule
        // a Web API refresh to recover the real state once Spotify's servers have it.
        let isProvisional = !notification.contextUri.isEmpty
            && notification.currentTrack == nil
            && notification.nextTracks.isEmpty
            && notification.prevTracks.isEmpty
        if isProvisional {
            debugLog("QueueService", "Provisional SetQueue (emitted before fill_up) — keeping existing queue, scheduling refresh")
            scheduleQueueRefresh()
            return
        }

        cancelPendingQueueRefresh()

        /// Convert to QueueEntries
        func toQueueEntry(_ trackInfo: SetQueueTrackInfo) -> QueueEntry? {
            guard let trackId = SpotifyAPI.parseTrackURI(trackInfo.uri) else { return nil }
            return QueueEntry(trackId: trackId, provider: TrackProvider(from: trackInfo.provider))
        }

        // Current track
        let currentEntry: QueueEntry? = notification.currentTrack.flatMap { toQueueEntry($0) }

        // Next tracks
        let nextEntries: [QueueEntry] = notification.nextTracks.compactMap { toQueueEntry($0) }

        // Previous tracks
        let prevEntries: [QueueEntry] = notification.prevTracks.compactMap { toQueueEntry($0) }

        store.setQueue(previous: prevEntries, current: currentEntry, next: nextEntries, contextUri: notification.contextUri)

        // Fetch track metadata for IDs not already in store
        let allIds = prevEntries.map(\.trackId) + (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)
        fetchTrackMetadata(for: allIds)
    }

    private func scheduleQueueRefresh() {
        pendingQueueRefreshTask?.cancel()
        pendingQueueRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let token = await tokenProvider()
            await fetchInitialPlaybackState(accessToken: token)
        }
    }

    private func cancelPendingQueueRefresh() {
        pendingQueueRefreshTask?.cancel()
        pendingQueueRefreshTask = nil
    }

    /// Handle queue update from Spirc callback (Mercury protocol)
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            debugLog("QueueService", "Queue callback was nil; keeping existing queue state")
            return
        }

        /// Convert QueueItem to QueueEntry (extract track ID and provider)
        func toQueueEntry(_ item: QueueItem) -> QueueEntry? {
            guard let trackId = SpotifyAPI.parseTrackURI(item.uri) else { return nil }
            return QueueEntry(trackId: trackId, provider: TrackProvider(from: item.provider))
        }

        let currentEntry: QueueEntry? = state.currentTrack.flatMap { toQueueEntry($0) }
        let nextEntries = state.nextTracks.compactMap { toQueueEntry($0) }
        // previousTracks is nil when from Web API (which doesn't provide history)
        let previousEntries = state.previousTracks?.compactMap { toQueueEntry($0) }

        if let prevCount = previousEntries?.count {
            debugLog("QueueService", "Queue updated from Mercury: prev=\(prevCount), current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")
        } else {
            debugLog("QueueService", "Queue updated from Web API: current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count) (preserving previous)")
        }

        store.setQueue(previous: previousEntries, current: currentEntry, next: nextEntries)

        // Real queue arrived — cancel any pending Web API refresh
        if !nextEntries.isEmpty {
            cancelPendingQueueRefresh()
        }

        // Fetch track metadata for IDs not already in store
        let allIds = (previousEntries ?? []).map(\.trackId) + (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)
        fetchTrackMetadata(for: allIds)
    }

    // MARK: - Metadata Fetching

    /// Fetch track metadata from Web API for tracks not already in the store
    /// Uses debouncing to avoid cancelling requests during rapid queue updates
    private func fetchTrackMetadata(for trackIds: [String]) {
        // Deduplicate IDs (queue can have duplicates)
        var seenIds = Set<String>()
        let uniqueTrackIds = trackIds.filter { seenIds.insert($0).inserted }

        guard !uniqueTrackIds.isEmpty else { return }

        // Filter to only tracks not already in the store
        let trackIdsToFetch = uniqueTrackIds.filter { store.tracks[$0] == nil }

        guard !trackIdsToFetch.isEmpty else {
            debugLog("QueueService", "All \(uniqueTrackIds.count) unique tracks already cached in store")
            // Update queue items from cached data
            updateNowPlayingMetadata()
            return
        }

        // Accumulate track IDs and debounce the fetch
        pendingTrackIds.formUnion(trackIdsToFetch)

        // Signal the debounced fetch
        fetchSubject.send()
    }

    /// Subscribe to debounced fetch requests
    /// Debounces rapid queue updates to avoid cancelling in-flight metadata fetches
    private func setupFetchDebounceSubscription() {
        fetchDebounceSubscription = fetchSubject
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in
                    await self?.executeFetch()
                }
            }
    }

    /// Execute the actual fetch for accumulated track IDs
    private func executeFetch() async {
        let trackIdsToFetch = Array(pendingTrackIds)
        pendingTrackIds.removeAll()

        guard !trackIdsToFetch.isEmpty else { return }

        // Don't cancel ongoing fetch - let it complete and just add more
        // Wait for any in-progress fetch to complete first
        if let existingTask = metadataFetchTask {
            _ = await existingTask.value
        }

        // Re-filter in case some were fetched by previous task
        let stillNeeded = trackIdsToFetch.filter { store.tracks[$0] == nil }
        guard !stillNeeded.isEmpty else {
            updateNowPlayingMetadata()
            return
        }

        debugLog("QueueService", "Fetching \(stillNeeded.count) tracks from Web API")

        metadataFetchTask = Task { [weak self, tokenProvider] in
            guard let self else { return }

            do {
                let accessToken = await tokenProvider()
                debugLog("QueueService", "Using token: \(String(accessToken.prefix(20)))...")
                let trackData = try await SpotifyAPI.fetchTracks(accessToken: accessToken, trackIds: stillNeeded)

                guard !Task.isCancelled else { return }

                // Convert APITrack to Track and store in the global store
                let tracksToStore = trackData.values.map { Track(from: $0) }

                // Store tracks in the global cache
                store.upsertTracks(tracksToStore)

                // Log each track's duration for debugging
                for track in tracksToStore {
                    debugLog("QueueService", "Cached track '\(track.name)' (\(track.id)): duration=\(track.durationMs)ms")
                }
                debugLog("QueueService", "Cached \(tracksToStore.count) tracks in store")

                // Update queue items from store
                updateNowPlayingMetadata()

            } catch {
                debugLog("QueueService", "Failed to fetch track metadata: \(error)")
            }
        }

        _ = await metadataFetchTask?.value
    }

    /// Update Now Playing info from current track in AppStore
    private func updateNowPlayingMetadata() {
        // Trigger Now Playing update - it reads from store.currentTrackEntity
        PlaybackViewModel.shared.updateNowPlayingInfo()

        let prevCount = store.previousTrackEntities.count
        let nextCount = store.nextTrackEntities.count
        let total = prevCount + (store.currentTrackEntity != nil ? 1 : 0) + nextCount
        debugLog("QueueService", "Queue tracks resolved: \(total) with metadata (prev=\(prevCount), next=\(nextCount))")
    }

    // MARK: - Initial State Fetch

    /// Fetches initial playback state and queue from Web API.
    /// Called after Spirc becomes ready to sync with whatever device is currently playing.
    /// Mercury only receives push updates, so we need this to get the current state.
    func fetchInitialPlaybackState(accessToken: String) async {
        debugLog("QueueService", "Fetching initial playback state from Web API...")

        // Fetch playback state and queue in parallel
        async let playbackStateTask = SpotifyAPI.fetchPlaybackState(accessToken: accessToken)
        async let queueTask = SpotifyAPI.fetchQueue(accessToken: accessToken)

        do {
            let (playbackState, queueResponse) = try await (playbackStateTask, queueTask)

            // Process queue response
            let currentEntry: QueueEntry? = queueResponse.currentlyPlaying.flatMap { track in
                QueueEntry(trackId: track.id, provider: .context)
            }
            let nextEntries: [QueueEntry] = queueResponse.queue.map { track in
                QueueEntry(trackId: track.id, provider: .context)
            }

            // Web API doesn't provide previous tracks, so preserve existing or use empty
            store.setQueue(previous: nil, current: currentEntry, next: nextEntries)

            debugLog("QueueService", "Initial queue: current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")

            // Fetch track metadata
            var allIds = (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)

            // Also add the track from playback state if different (shouldn't be, but just in case)
            if let playbackTrack = playbackState?.item, !allIds.contains(playbackTrack.id) {
                allIds.append(playbackTrack.id)
            }

            fetchTrackMetadata(for: allIds)

            // Process playback state if available
            if let state = playbackState {
                // Get duration from playback state, or fall back to queue's currently playing track
                let playbackStateDuration = state.item?.durationMs
                let queueDuration = queueResponse.currentlyPlaying?.durationMs
                let durationMs = playbackStateDuration ?? queueDuration ?? 0

                debugLog(
                    "QueueService",
                    "Initial playback: playing=\(state.isPlaying), progress=\(state.progressMs ?? 0)ms, " +
                        "duration from /me/player: \(playbackStateDuration.map { String($0) } ?? "nil"), " +
                        "duration from /me/player/queue: \(queueDuration.map { String($0) } ?? "nil"), " +
                        "using duration: \(durationMs)ms, device=\(state.device?.name ?? "unknown")",
                )

                // Update PlaybackViewModel with the current state
                let vm = PlaybackViewModel.shared
                vm.applyWebAPIPlaybackState(
                    isPlaying: state.isPlaying,
                    progressMs: state.progressMs ?? 0,
                    durationMs: durationMs,
                    trackUri: state.item?.uri ?? queueResponse.currentlyPlaying?.uri,
                    timestampMs: state.timestamp ?? 0,
                    shuffleEnabled: state.shuffleState ?? false,
                )
            }
        } catch {
            debugLog("QueueService", "Failed to fetch initial playback state: \(error)")
        }
    }
}
