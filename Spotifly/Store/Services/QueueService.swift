//
//  QueueService.swift
//  Spotifly
//
//  Service for queue-related operations.
//  Queue structure (track URIs) is published by LibrespotClient, which owns the queue.
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

        // The client publishes both shapes together whenever its queue moves. This one
        // carries the resolved entries the store renders.
        queueSubscription = SpotifyPlayer.queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queueState in
                self?.handleQueueUpdate(queueState)
            }

        // And this one carries the context uri beside them, which is what a queue *set*
        // — locally or by a remote command — has to record.
        setQueueSubscription = SpotifyPlayer.setQueue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleSetQueue(notification)
            }

        // Debounced so rapid queue updates do not cancel an in-flight metadata fetch.
        fetchDebounceSubscription = fetchSubject
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor in
                    await self?.executeFetch()
                }
            }

        log("activated")
    }

    // MARK: - Queue Updates

    /// Handle set queue notification (fires immediately when queue is set or context is loaded)
    private func handleSetQueue(_ notification: SetQueueNotification) {
        let contextInfo = notification.contextUri.isEmpty ? "" : " context=\(notification.contextUri),"
        log("Set queue:\(contextInfo) prev=\(notification.prevTracks.count), current=\(notification.currentTrack != nil ? 1 : 0), next=\(notification.nextTracks.count)")

        // A SetQueue with a context URI but no tracks is provisional: the Rust path emitted
        // one during context setup, before `fill_up_next_tracks` had filled the queue in.
        // `LibrespotClient` resolves a context to its full track list before publishing, so
        // this should not fire any more; it stays because the alternative to keeping the
        // existing queue and refreshing is blanking it.
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

        let currentEntry = notification.currentTrack.flatMap(Self.queueEntry(from:))
        let nextEntries = notification.nextTracks.compactMap(Self.queueEntry(from:))
        let prevEntries = notification.prevTracks.compactMap(Self.queueEntry(from:))

        store.setQueue(previous: prevEntries, current: currentEntry, next: nextEntries, contextUri: notification.contextUri)
        reconcileQueueCurrentTrack()

        fetchTrackMetadata(for: Self.trackIds(prevEntries, currentEntry, nextEntries))
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

    /// Handle a queue update published by the client.
    private func handleQueueUpdate(_ queueState: QueueState?) {
        guard let state = queueState else {
            log("Queue update was nil; keeping existing queue state")
            return
        }

        let currentEntry = state.currentTrack.flatMap(Self.queueEntry(from:))
        let nextEntries = state.nextTracks.compactMap(Self.queueEntry(from:))
        // previousTracks is nil when from Web API (which doesn't provide history)
        let previousEntries = state.previousTracks?.compactMap(Self.queueEntry(from:))

        if let prevCount = previousEntries?.count {
            log("Queue updated from the player: prev=\(prevCount), current=\(currentEntry != nil ? 1 : 0), next=\(nextEntries.count)")
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

        fetchTrackMetadata(for: Self.trackIds(previousEntries ?? [], currentEntry, nextEntries))
    }

    // MARK: - Metadata Fetching

    /// Fetch track metadata from Web API for tracks not already in the store
    /// Uses debouncing to avoid cancelling requests during rapid queue updates
    private func fetchTrackMetadata(for trackIds: [String]) {
        // A queue can name the same track more than once.
        let uniqueTrackIds = trackIds.uniqued()
        guard !uniqueTrackIds.isEmpty else { return }

        let trackIdsToFetch = uniqueTrackIds.filter { store.tracks[$0] == nil }

        guard !trackIdsToFetch.isEmpty else {
            log("All \(uniqueTrackIds.count) unique tracks already cached in store")
            updateNowPlayingMetadata()
            return
        }

        pendingTrackIds.formUnion(trackIdsToFetch)
        fetchSubject.send()
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

    /// Adopts whatever the Connect cluster last said is playing.
    ///
    /// **This used to be two Web API requests**, `/me/player` and `/me/player/queue`, asked
    /// because the push channel only pushes and a client that just started had never been
    /// pushed to. The cluster answers both, and the dealer already receives it — so this
    /// reads a snapshot of the last update rather than going to the network.
    ///
    /// Two consequences of having one source instead of two. The **freshness barrier is gone**:
    /// it existed because an HTTP snapshot could be older than live state that landed while
    /// it was in flight, and a snapshot that *is* the last live update cannot be. And the
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

        fetchTrackMetadata(for: Self.trackIds(update.previous, update.current, update.next))

        return true
    }

    /// The whole queue's track ids in play order, which is what a metadata fetch needs.
    private static func trackIds(
        _ previous: [QueueEntry],
        _ current: QueueEntry?,
        _ next: [QueueEntry],
    ) -> [String] {
        (previous + (current.map { [$0] } ?? []) + next).map(\.trackId)
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

    /// A queue track becomes an entry only if its uri names a track — the cluster can carry
    /// episodes and ads, which this app has no row for.
    private static func queueEntry(uri: String, provider: String) -> QueueEntry? {
        guard let trackId = SpotifyAPI.parseTrackURI(uri) else { return nil }
        return QueueEntry(trackId: trackId, provider: TrackProvider(from: provider))
    }

    /// The two shapes a queue track arrives in: an item of a cluster snapshot, and a track
    /// of a SetQueue notification.
    private static func queueEntry(from item: QueueItem) -> QueueEntry? {
        queueEntry(uri: item.uri, provider: item.provider)
    }

    private static func queueEntry(from track: SetQueueTrackInfo) -> QueueEntry? {
        queueEntry(uri: track.uri, provider: track.provider)
    }
}
