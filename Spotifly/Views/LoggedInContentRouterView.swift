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

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    let onLogout: () -> Void

    var body: some View {
        NavigationStack(path: Bindable(navigationCoordinator).navigationPath) {
            Group {
                if let query = navigationCoordinator.displayedSearchQuery,
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
            .navigationDestination(for: NavigationDestination.self) { destination in
                destinationView(for: destination)
            }
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
            AlbumDetailView(
                albumId: id,
            )

        case let .playlist(id):
            PlaylistDetailView(
                playlistId: id,
            )

        case let .searchTracks(ids):
            SearchAllTracksView(
                trackIds: ids,
            )
        }
    }
}
