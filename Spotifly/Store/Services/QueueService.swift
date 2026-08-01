//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue structure (track URIs) is received from Spirc via Mercury protocol.
//  Track metadata is loaded through TrackService and cached in the store.
//

import Combine
import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let tokenProvider: () async -> String
    private let trackService: TrackService
    private var queueSubscription: AnyCancellable?
    private var setQueueSubscription: AnyCancellable?
    private var pendingQueueRefreshTask: Task<Void, Never>?
    private var pendingTrackIds: Set<String> = []
    /// Subject for debouncing metadata fetch requests
    private let fetchSubject = PassthroughSubject<Void, Never>()
    /// Subscription for debounced fetch operations
    private var fetchDebounceSubscription: AnyCancellable?

    /// Identifies this instance and the store it holds in the log.
    ///
    /// SwiftUI runs a View's `init` repeatedly and keeps only the first
    /// `State(initialValue:)`, so more than one of these can exist. Only the activated one
    /// should ever appear in the log; a second tag means a discarded instance came alive.
    private let tag: String
    private static var instanceCount = 0

    private func log(_ message: String) {
        debugLog("QueueService", "\(tag) \(message)")
    }

    init(
        store: AppStore,
        tokenProvider: @escaping () async -> String,
        trackService: TrackService,
    ) {
        Self.instanceCount += 1
        tag = "[svc#\(Self.instanceCount) store:\(storeTag(store))]"
        self.store = store
        self.tokenProvider = tokenProvider
        self.trackService = trackService
    }

    /// Starts listening to the player. Call once, from the view that actually kept this
    /// instance — see `activate()` on the sibling services for why `init` must not do it.
    ///
    /// Idempotent: a `.task` runs again when its view reappears, and the guard reads the
    /// subscription it protects rather than a separate flag that could drift from it.
    func activate() {
        guard setQueueSubscription == nil else { return }
        recordActivation(self)
        setupQueueSubscription()
        setupSetQueueSubscription()
        setupFetchDebounceSubscription()
        log("activated")
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
        log("Set queue:\(contextInfo) prev=\(notification.prevTracks.count), current=\(notification.currentTrack != nil ? 1 : 0), next=\(notification.nextTracks.count)")

        // A SetQueue with a context URI but no tracks is provisional: librespot emits it during
        // context setup before fill_up_next_tracks completes. Keep the existing queue and schedule
        // a Web API refresh to recover the real state once Spotify's servers have it.
        let isProvisional = !notification.contextUri.isEmpty
            && notification.currentTrack == nil
            && notification.nextTracks.isEmpty
            && notification.prevTracks.isEmpty
        if isProvisional {
            log("Provisional SetQueue (emitted before fill_up) — keeping existing queue, scheduling refresh")
            // Deliberately does not bump the live-state revision: this notification carries
            // no usable queue, and the refresh it schedules is a Web API fetch that the
            // freshness barrier would otherwise discard as stale.
            scheduleQueueRefresh()
            return
        }

        cancelPendingQueueRefresh()
        store.noteLiveStateReceived()

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

    /// Number of times a queue refresh may be re-attempted after coming back empty-handed.
    private static let queueRefreshAttempts = 3

    private func scheduleQueueRefresh() {
        pendingQueueRefreshTask?.cancel()
        pendingQueueRefreshTask = Task { @MainActor [weak self] in
            // This refresh exists to recover a queue librespot has not filled in yet, so it
            // is the one caller of the bootstrap that cannot simply accept a discarded
            // response. A live callback landing mid-fetch drops the whole Web API snapshot,
            // including the queue being waited for, and nothing else would go looking for it
            // again. Retrying is bounded so a steady stream of callbacks cannot keep it
            // alive; a real SetQueue cancels the task outright.
            //
            // Each attempt issues fresh requests and captures the live revision anew, so a
            // retry is not the discarded snapshot coming back — it is a newer one, taken
            // after the callback that invalidated the last. What it cannot rule out is the
            // Web API lagging the live state, which is what the sleep before each attempt is
            // for, and which every caller of the bootstrap already accepts.
            for _ in 0 ..< Self.queueRefreshAttempts {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                let token = await tokenProvider()
                if await fetchInitialPlaybackState(accessToken: token) {
                    return
                }
                log("Queue refresh did not apply — retrying")
            }
        }
    }

    private func cancelPendingQueueRefresh() {
        pendingQueueRefreshTask?.cancel()
        pendingQueueRefreshTask = nil
    }

    /// Handle queue update from Spirc callback (Mercury protocol)
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            log("Queue callback was nil; keeping existing queue state")
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
            log("Queue updated from Mercury: prev=\(prevCount), current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")
        } else {
            log("Queue updated from Web API: current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count) (preserving previous)")
        }

        store.noteLiveStateReceived()
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
            log("All \(uniqueTrackIds.count) unique tracks already cached in store")
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

        log("Ensuring metadata for \(trackIdsToFetch.count) queue tracks")

        do {
            try await trackService.ensureTracksLoaded(trackIds: trackIdsToFetch)
            updateNowPlayingMetadata()
        } catch {
            log("Failed to fetch track metadata: \(error)")
        }
    }

    /// Update Now Playing info from current track in AppStore
    private func updateNowPlayingMetadata() {
        // Trigger Now Playing update - it resolves PlaybackViewModel's logical URI.
        PlaybackViewModel.shared.updateNowPlayingInfo()

        let prevCount = store.previousTrackEntities.count
        let nextCount = store.nextTrackEntities.count
        let total = prevCount + (store.currentTrackEntity != nil ? 1 : 0) + nextCount
        log("Queue tracks resolved: \(total) with metadata (prev=\(prevCount), next=\(nextCount))")
    }

    // MARK: - Initial State Fetch

    /// Fetches initial playback state and queue from Web API.
    /// Called after Spirc becomes ready to sync with whatever device is currently playing.
    /// Mercury only receives push updates, so we need this to get the current state.
    ///
    /// - Returns: `false` when nothing was applied, either because the request failed or
    ///   because live state from Rust advanced while it was in flight. Most callers can
    ///   ignore that — a discarded response means the live callbacks already told Swift
    ///   what it was about to learn. Whether the queue *contents* changed is not a usable
    ///   substitute: a provisional `SetQueue` preserves the previous queue, so a discarded
    ///   response and an applied one can leave identical-looking state.
    @discardableResult
    func fetchInitialPlaybackState(accessToken: String) async -> Bool {
        log("Fetching initial playback state from Web API...")

        // Freshness barrier: remember where live state stood before going to the network.
        // Rust callbacks can land while these requests are in flight, and they are
        // authoritative — applying the response afterwards would replace correct live state
        // with an older snapshot, which looks like Swift not knowing what Rust is doing.
        let revisionBeforeFetch = store.liveStateRevision

        // Fetch playback state and queue in parallel
        async let playbackStateTask = SpotifyAPI.fetchPlaybackState(accessToken: accessToken)
        async let queueTask = SpotifyAPI.fetchQueue(accessToken: accessToken)

        do {
            let (playbackState, queueResponse) = try await (playbackStateTask, queueTask)

            guard store.liveStateRevision == revisionBeforeFetch else {
                debugLog(
                    "QueueService",
                    "Discarding Web API bootstrap: live state advanced from \(revisionBeforeFetch) to \(store.liveStateRevision) while fetching",
                )
                return false
            }

            // Process queue response
            let currentEntry: QueueEntry? = queueResponse.currentlyPlaying.flatMap { track in
                QueueEntry(trackId: track.logicalId, provider: .context)
            }
            let nextEntries: [QueueEntry] = queueResponse.queue.map { track in
                QueueEntry(trackId: track.logicalId, provider: .context)
            }

            // Web API doesn't provide previous tracks, so preserve existing or use empty
            store.setQueue(previous: nil, current: currentEntry, next: nextEntries)

            log("Initial queue: current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")

            // Fetch track metadata
            var allIds = (currentEntry.map { [$0.trackId] } ?? []) + nextEntries.map(\.trackId)

            // Also add the track from playback state if different (shouldn't be, but just in case)
            if let playbackTrack = playbackState?.item, !allIds.contains(playbackTrack.logicalId) {
                allIds.append(playbackTrack.logicalId)
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
                    trackUri: state.item?.logicalUri ?? queueResponse.currentlyPlaying?.logicalUri,
                    timestampMs: state.timestamp ?? 0,
                    shuffleEnabled: state.shuffleState ?? false,
                )
            }

            return true
        } catch {
            log("Failed to fetch initial playback state: \(error)")
            return false
        }
    }
}
