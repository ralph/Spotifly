//
//  LoggedInContentRouterView.swift
//  Spotifly
//
//  Routes the main logged-in content column based on coordinator state.
//

import SwiftUI

struct LoggedInContentRouterView: View {
    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(SearchService.self) private var searchService

    let onLogout: () -> Void

    /// The route's last drill-down, or else its section's page.
    ///
    /// Drawn here rather than pushed onto a `NavigationStack`: the split view's detail column
    /// takes over a stack's pushes and shows the pushed page in place of the whole column, so
    /// everything `LoggedInView` lays around the router, the now-playing bar, the room under
    /// each page, the content toolbar and the playback alerts, was missing on it.
    var body: some View {
        if let destination = navigationCoordinator.navigationPath.last {
            destinationView(for: destination)
        } else if let query = navigationCoordinator.displayedSearchQuery,
                  let searchResults = store.searchResults(for: query)
        {
            SearchResultsView(searchResults: searchResults)
                .navigationTitle("nav.search_results")
        } else if let query = navigationCoordinator.displayedSearchQuery,
                  let failure = store.searchFailure(for: query)
        {
            InlineLoadError(failure: failure) { await searchService.search(query: query) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("nav.search_results")
        } else {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch navigationCoordinator.selectedNavigationItem {
        case .startpage:
            StartpageView()
                .navigationTitle("nav.startpage")

        case .favorites:
            FavoritesListView()
                .navigationTitle("nav.favorites")

        case .playlists:
            PlaylistsListView()
                .navigationTitle("nav.playlists")

        case .albums:
            AlbumsListView()
                .navigationTitle("nav.albums")

        case .artists:
            ArtistsListView()
                .navigationTitle("nav.artists")

        case .queue:
            QueueListView()
                .navigationTitle("nav.queue")

        case .speakers:
            SpeakersView()
                .navigationTitle("nav.speakers")

        case .profile:
            // Drawn whether or not the profile loaded. `onLogout` is LoggedInView's
            // handleLogout, which already stops playback — and which is the only way to clear a
            // revoked grant from inside the app, so it must not be gated on a request that the
            // same revoked grant would have failed.
            UserProfileView(userProfile: store.userProfile, onLogout: onLogout)

        case .searchResults:
            EmptyView()

        case .none:
            Text("empty.select_item")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        switch destination {
        case let .artist(id):
            ArtistDetailView(artistId: id)

        case let .album(id):
            AlbumDetailView(albumId: id)

        case let .playlist(id):
            PlaylistDetailView(playlistId: id)

        case let .searchTracks(ids):
            SearchAllTracksView(trackIds: ids)
        }
    }
}
