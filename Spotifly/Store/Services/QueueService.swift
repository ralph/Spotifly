//
//  QueueService.swift
//  Spotifly
//
//  Keeps the store holding metadata for every track the player's queue names, and the
//  store and playback agreeing on which tracks will not play. The queue itself is the
//  player's: `PlayerModel.queueEntries`.
//

import Foundation

@MainActor
@Observable
final class QueueService {
    private let store: AppStore
    private let trackService: TrackService
    private let player: PlayerModel
    /// Tells playback which tracks the lists said will not play; injected for tests.
    private let setUnplayable: @MainActor (Set<String>) -> Void
    private var queueObservation: Task<Void, Never>?
    private var withheldObservation: Task<Void, Never>?
    private var unplayableObservation: Task<Void, Never>?

    /// Identifies this instance and the store it holds in the log. A session makes one, so a
    /// second tag in a run means a second session, after a logout and a login.
    private let tag: String
    private static var instanceCount = 0

    private func log(_ message: String) {
        debugLog("QueueService", "\(tag) \(message)")
    }

    init(
        store: AppStore,
        trackService: TrackService,
        player: PlayerModel = .shared,
        setUnplayable: @escaping @MainActor (Set<String>) -> Void = SpotifyPlayer.setUnplayable,
    ) {
        Self.instanceCount += 1
        tag = "[svc#\(Self.instanceCount) store:\(storeTag(store))]"
        self.store = store
        self.trackService = trackService
        self.player = player
        self.setUnplayable = setUnplayable
    }

    /// The observations hold the service weakly, but would otherwise wait on the player, which
    /// outlives a logout, until its next change; withheld tracks can go unchanged until the app
    /// quits.
    isolated deinit {
        queueObservation?.cancel()
        withheldObservation?.cancel()
        unplayableObservation?.cancel()
    }

    /// Starts following the player and the store, from the logged-in view's launch task.
    ///
    /// Idempotent: that task runs again when a window reopens on the session, and the guard reads
    /// an observation it protects, all set together, rather than a separate flag that could drift.
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

        // What playback found withheld, which no list said, is greyed. As it stands too, so the
        // store of a new login starts from the player's set.
        withheldObservation = Task { [weak self, player] in
            for await uris in Observations({ player.withheld }) {
                guard let self else { return }
                if !uris.isEmpty {
                    log("Playback found \(uris.count) withheld, greying them")
                }
                store.setWithheld(uris)
            }
        }

        // And the other way: playback steps over what the lists said will not play. As it
        // stands too, which tells a new login's player an empty set, so nothing of the previous
        // account's is left. Here rather than in a window, which the store outlives.
        unplayableObservation = Task { [weak self] in
            for await uris in Observations({ [weak self] in self?.store.unplayableTrackUris ?? [] }) {
                guard let self else { return }
                setUnplayable(uris)
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
