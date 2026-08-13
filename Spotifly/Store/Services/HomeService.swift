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
/// **The layout is Spotify's, not the app's.** There is no fixed set of sections to ask for and
/// no ordering to impose: the response is a list of titled shelves, and this renders whatever
/// arrives. That is why there is no per-section loading state — one request either produced a
/// page or did not.
@MainActor
@Observable
final class HomeService {
    private let store: AppStore
    private let partnerAPI: PartnerAPI

    /// In-flight load. Stored so concurrent callers await the same one, and — because it is an
    /// unstructured Task — so the load survives cancellation of the caller's `.task`. Mirrors
    /// the library services.
    private var loadTask: Task<Void, Never>?

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

        let task = Task {
            defer {
                self.loadTask = nil
                self.store.homeIsLoading = false
            }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    func refresh() async {
        await loadHome(forceRefresh: true)
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
            store.setHomePage(sections: page.sections, greeting: page.greeting)

            store.hasLoadedHome = true
        } catch is CancellationError {
            // A superseded load leaves the page as it was rather than reporting a failure.
        } catch {
            store.homeErrorMessage = error.localizedDescription
        }
    }
}
