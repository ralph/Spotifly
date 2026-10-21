//
//  HomeService.swift
//  Spotifly
//
//  The start page: one request, whatever shelves Spotify sends back.
//

import Foundation

/// Loads Spotify's own start page.
///
/// **Replaces three services' worth of work with one request.** The page used to be assembled
/// from `/me/top/artists`, `/me/top/tracks` and `/me/player/recently-played`, and the last of
/// those named its items by uri only — so every album, playlist and artist in the recent strip
/// cost a further request to resolve. `home` returns the shelves with their contents inline.
///
/// The page shows one of its shelves, the contexts last played, beside the listener's top
/// tracks and artists, which `userTopContent` gives by time range (`plans/done/redesign-home.md`).
/// The shelves are one request and one loading state; each range of top content is another.
@MainActor
@Observable
final class HomeService {
    private let store: AppStore
    private let partnerAPI: PartnerAPI

    /// In-flight load. Stored so concurrent callers await the same one, and — because it is an
    /// unstructured Task — so the load survives cancellation of the caller's `.task`. Mirrors
    /// the library services.
    private var loadTask: Task<Void, Never>?

    /// Which load is current. **Cancelling a task does not stop it where it stands** — it
    /// unblocks the `await`, and the cancelled run then finishes its own teardown, possibly
    /// after a replacement has already registered itself. Without this, the loser's cleanup
    /// clears the winner's `loadTask` and turns its loading flag off: a third caller would
    /// start a third request instead of joining, and the spinner would stop while a load was
    /// still running. Pressing ⌘R six times in four seconds, which is exactly what a refresh
    /// that changes nothing visible invites, is enough to reach it.
    private var loadGeneration = 0

    /// One load per top-content range, keyed by its raw value.
    private let topContentRequests = InFlightRequests<Void>()

    /// The ranges the page has asked for, loaded or not, which a refresh loads again: one that
    /// failed is absent from the store, and would otherwise never be retried.
    private var requestedTopContentRanges: Set<TopContentRange> = []

    /// How many top tracks and artists a range lists.
    private static let topContentLimit = 10

    init(store: AppStore, partnerAPI: PartnerAPI = PartnerAPI()) {
        self.store = store
        self.partnerAPI = partnerAPI
    }

    /// Loads the page, or awaits the load already running. Does nothing once loaded unless
    /// `forceRefresh` is set.
    func loadHome(forceRefresh: Bool = false) async {
        if !forceRefresh, store.hasLoadedHome {
            return
        }

        if forceRefresh {
            loadTask?.cancel()
            loadTask = nil
        }

        if let existingTask = loadTask {
            await existingTask.value
            return
        }

        store.homeIsLoading = true
        store.homeErrorMessage = nil

        loadGeneration += 1
        let generation = loadGeneration

        let task = Task {
            defer {
                if self.loadGeneration == generation {
                    self.loadTask = nil
                    self.store.homeIsLoading = false
                }
            }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    /// Reloads the shelves and every top-content range already shown, all at once.
    func refresh() async {
        await withTaskGroup { group in
            group.addTask { await self.loadHome(forceRefresh: true) }
            for range in requestedTopContentRanges {
                group.addTask { await self.loadTopContent(range: range, forceRefresh: true) }
            }
        }
    }

    /// Loads one range's top tracks and artists, or joins the load already running. Does
    /// nothing once loaded unless `forceRefresh` is set. A failure leaves the range as it was:
    /// the section shows what it had, or nothing, as the start page has no error per section.
    func loadTopContent(range: TopContentRange, forceRefresh: Bool = false) async {
        requestedTopContentRanges.insert(range)
        if !forceRefresh, store.topContent[range] != nil {
            return
        }

        do {
            try await topContentRequests.run(range.rawValue) {
                let response = try await self.partnerAPI.topContent(range: range, limit: Self.topContentLimit)
                try Task.checkCancellation()
                let tracks = response.tracks
                let artists = response.artists
                // Only the tracks the store has not got: these name no playability, and would
                // mark a track an album or playlist knows to be unplayable playable again.
                self.store.upsertTracks(tracks.filter { self.store.tracks[$0.id] == nil })
                self.store.upsertArtists(artists)
                self.store.setTopContent(
                    TopContent(trackIds: tracks.map(\.id), artistIds: artists.map(\.id)),
                    for: range,
                )
            }
        } catch {
            debugLog("HomeService", "Top content \(range.rawValue) failed: \(error)")
        }
    }

    private func performLoad() async {
        do {
            let page = try await HomePage(pathfinder: partnerAPI.home())

            try Task.checkCancellation()

            // Entities before shelves: a shelf holds ids, and an id the store has no entity for
            // is a card that cannot draw.
            store.upsertAlbums(page.albums)
            store.upsertPlaylists(page.playlists)
            store.upsertArtists(page.artists)
            store.setHomePage(sections: page.sections)

            store.hasLoadedHome = true
        } catch is CancellationError {
            // A superseded load leaves the page as it was rather than reporting a failure.
        } catch {
            store.homeErrorMessage = error.localizedDescription
        }
    }
}
