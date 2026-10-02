//
//  QueueService.swift
//  Spotifly
//
//  Keeps the store holding metadata for every track the player's queue names.
//  The queue itself is the player's: `PlayerModel.queueEntries`.
//

import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let trackService: TrackService
    private let player: PlayerModel
    private var queueObservation: Task<Void, Never>?

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
                let rows = player.queueEntries
                let contextInfo = queue?.context.map { " context=\($0)," } ?? ""
                log("Queue updated from the player:\(contextInfo) prev=\(rows.previousTracks.count), current=\(rows.currentTrack != nil ? 1 : 0), next=\(rows.nextTracks.count)")
                hydrate()
            }
        }

        log("activated")
    }

    // MARK: - Metadata

    /// Makes sure the store holds the metadata of every track the queue names, then updates Now
    /// Playing, which reads the current track's from the store.
    ///
    /// Called on every change of the queue, and again when the network returns: nothing else
    /// would retry a fetch that failed offline, since the queue can come back as it was and the
    /// player model then publishes no change. A track the store holds costs no request, and one
    /// another call is already fetching joins that run (`TrackService.ensureTracksLoaded`).
    func hydrate() {
        let trackIds = player.queueEntries.trackIds
        guard !trackIds.isEmpty else { return }
        Task {
            do {
                try await trackService.ensureTracksLoaded(trackIds: trackIds)
            } catch {
                log("Failed to fetch track metadata: \(error)")
                return
            }
            PlaybackViewModel.shared.updateNowPlayingInfo()
            let resolved = trackIds.count(where: { store.tracks[$0] != nil })
            log("Queue tracks resolved: \(resolved) of \(trackIds.count) with metadata")
        }
    }
}
