//
//  QueueService.swift
//  Spotifly
//
//  Keeps the store holding metadata for every track the player's queue names.
//  The queue itself is the player's: `PlayerModel.queueEntries`.
//

import Combine
import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let trackService: TrackService
    private let player: PlayerModel
    private var queueObservation: Task<Void, Never>?
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
        player: PlayerModel = .shared,
    ) {
        Self.instanceCount += 1
        tag = "[svc#\(Self.instanceCount) store:\(storeTag(store))]"
        self.store = store
        self.trackService = trackService
        self.player = player
    }

    /// Starts listening to the player. Call once, from the view that actually kept this
    /// instance — see `activate()` on the sibling services for why `init` must not do it.
    ///
    /// Idempotent: a `.task` runs again when its view reappears, and the guard reads the
    /// observation it protects rather than a separate flag that could drift from it.
    func activate() {
        guard queueObservation == nil else { return }
        recordActivation(self)

        // The whole queue, with its context, as the player last published it: first as it
        // stands, then on every change.
        queueObservation = Task { [weak self, player] in
            for await queue in Observations({ player.queue }) {
                guard let self else { return }
                handleQueueUpdate(queue)
            }
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

    /// Asks for the metadata of a queue the player published.
    private func handleQueueUpdate(_ queueState: QueueState?) {
        let queue = Queue(queueState)
        let contextInfo = queueState?.context.map { " context=\($0)," } ?? ""
        log("Queue updated from the player:\(contextInfo) prev=\(queue.previousTracks.count), current=\(queue.currentTrack != nil ? 1 : 0), next=\(queue.nextTracks.count)")

        fetchTrackMetadata(for: queue.trackIds)
    }

    /// Asks again for the metadata of every track the queue names that the store lacks.
    ///
    /// The observation asks whenever the queue changes, but nothing else retries a fetch that
    /// failed, offline say: after a reconnect or a remote start the queue can come back as it
    /// was, and the player model then publishes no change. A track the store holds costs no
    /// request.
    func hydrate() {
        fetchTrackMetadata(for: player.queueEntries.trackIds)
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

        let trackIds = player.queueEntries.trackIds
        let resolved = trackIds.count(where: { store.tracks[$0] != nil })
        log("Queue tracks resolved: \(resolved) of \(trackIds.count) with metadata")
    }
}
