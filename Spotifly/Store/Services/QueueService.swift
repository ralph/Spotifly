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
        trackService: TrackService,
    ) {
        Self.instanceCount += 1
        tag = "[svc#\(Self.instanceCount) store:\(storeTag(store))]"
        self.store = store
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
        reconcileQueueCurrentTrack()

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
                if await fetchInitialPlaybackState() {
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

    /// Queue and playback callbacks arrive through independent main-actor hops. Reconcile
    /// after every usable queue update as well as when PlaybackViewModel changes the URI,
    /// so whichever signal arrives second repairs the split.
    private func reconcileQueueCurrentTrack() {
        guard let currentTrackUri = PlaybackViewModel.shared.currentTrackUri,
              let trackId = SpotifyAPI.parseTrackURI(currentTrackUri),
              store.reconcileQueueCurrentTrack(with: trackId)
        else { return }

        log("Reconciled queue current pointer to \(trackId) at index \(store.currentIndex)")
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
        reconcileQueueCurrentTrack()

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

    /// Whether a Web API bootstrap response says anything at all about playback.
    ///
    /// Spotify answers both `/me/player` and `/me/player/queue` with 204 when no device is
    /// active, and those decode to a nil state and an empty queue — indistinguishable from a
    /// genuinely empty queue. It is the *absence of an answer*, not an answer that nothing is
    /// queued, and the difference decides whether the queue survives a reconnect.
    ///
    /// Applying it is worse than it looks, because `AppStore.setQueue`'s `previous: nil`
    /// contract splits the queue the wrong way round: the history is preserved and the
    /// pending tracks — the one part no later callback reconstructs — are destroyed, along
    /// with the current pointer that `Queue.reconciled` then cannot repair, because it can
    /// only re-split a list that still contains the track.
    /// Adopts whatever the Connect cluster last said is playing.
    ///
    /// **This used to be two Web API requests**, `/me/player` and `/me/player/queue`, asked
    /// because Mercury only pushes and a client that just started had never been pushed to.
    /// The cluster answers both, and librespot already receives it — so this reads a snapshot
    /// of the last update rather than going to the network.
    ///
    /// Two consequences of having one source instead of two. The **freshness barrier is gone**:
    /// it existed because an HTTP snapshot could be older than a Rust callback that landed
    /// while it was in flight, and a snapshot that *is* the last callback cannot be. And the
    /// **previous tracks survive** — `/me/player/queue` returned none at all, so the old code
    /// had to pass `previous: nil` and hope something else filled it in.
    ///
    /// - Returns: `false` when nothing was applied, which for this source means only one
    ///   thing: no cluster update has arrived yet. Callers that can wait should try again —
    ///   `scheduleQueueRefresh` is the one that must.
    @discardableResult
    func fetchInitialPlaybackState() async -> Bool {
        guard let update = Self.queueUpdate(from: currentQueueSnapshot()) else {
            log("Cluster says nothing usable yet — keeping the existing queue")
            return false
        }

        store.setQueue(previous: update.previous, current: update.current, next: update.next)
        reconcileQueueCurrentTrack()

        log("Initial queue: prev=\(update.previous.count), current=\(update.current != nil ? 1 : 0), next=\(update.next.count)")

        let allIds = update.previous.map(\.trackId)
            + (update.current.map { [$0.trackId] } ?? [])
            + update.next.map(\.trackId)
        fetchTrackMetadata(for: allIds)

        return true
    }

    /// What a cluster snapshot resolves to, or **nil when it must not be applied**.
    ///
    /// This is the guard that `responseCarriesPlayback` used to be, and it exists for the same
    /// reason: an answer meaning "I have nothing to tell you" decodes identically to one
    /// meaning "nothing is queued", and applying the second when you were given the first
    /// wipes a real queue. That is what emptied the queue on every wake from sleep — see
    /// `plans/wake-from-sleep-loses-queue-and-resume.md`.
    ///
    /// The two forms it takes here: **nil**, when no cluster update has arrived at all, and a
    /// snapshot that yields no current track and nothing pending. Previous tracks alone are
    /// not enough — history with nothing playing is what a wiped queue looks like.
    static func queueUpdate(
        from snapshot: QueueState?,
    ) -> (previous: [QueueEntry], current: QueueEntry?, next: [QueueEntry])? {
        guard let snapshot else { return nil }

        let current = snapshot.currentTrack.flatMap(queueEntry(from:))
        let next = snapshot.nextTracks.compactMap(queueEntry(from:))
        let previous = (snapshot.previousTracks ?? []).compactMap(queueEntry(from:))

        guard current != nil || !next.isEmpty else { return nil }

        return (previous, current, next)
    }

    /// A queue item becomes an entry only if its uri names a track — the cluster can carry
    /// episodes and ads, which this app has no row for.
    private static func queueEntry(from item: QueueItem) -> QueueEntry? {
        guard let trackId = SpotifyAPI.parseTrackURI(item.uri) else { return nil }
        return QueueEntry(trackId: trackId, provider: TrackProvider(from: item.provider))
    }
}
