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

    @Bindable var playbackViewModel: PlaybackViewModel
    let onLogout: () -> Void

    private var navigationPathBinding: Binding<[NavigationDestination]> {
        Binding(
            get: { navigationCoordinator.navigationPath },
            set: { navigationCoordinator.setNavigationPath($0) },
        )
    }

    private var navigationSelectionBinding: Binding<NavigationItem?> {
        Binding(
            get: { navigationCoordinator.selectedNavigationItem },
            set: { navigationCoordinator.selectNavigationItem($0) },
        )
    }

    var body: some View {
        NavigationStack(path: navigationPathBinding) {
            Group {
                if let query = navigationCoordinator.displayedSearchQuery,
                   let searchResults = store.searchResults(for: query)
                {
                    SearchResultsView(searchResults: searchResults, playbackViewModel: playbackViewModel)
                        .navigationTitle("nav.search_results")
                } else {
                    contentView
                        .playbackShortcuts(playbackViewModel: playbackViewModel)
                        .libraryNavigationShortcuts(selection: navigationSelectionBinding)
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
            FavoritesListView(playbackViewModel: playbackViewModel)
                .navigationTitle("nav.favorites")

        case .playlists:
            PlaylistsListView(playbackViewModel: playbackViewModel)
                .navigationTitle("nav.playlists")

        case .albums:
            AlbumsListView(playbackViewModel: playbackViewModel)
                .navigationTitle("nav.albums")

        case .artists:
            ArtistsListView(playbackViewModel: playbackViewModel)
                .navigationTitle("nav.artists")

        case .queue:
            QueueListView(playbackViewModel: playbackViewModel)
                .navigationTitle("nav.queue")

        case .speakers:
            SpeakersView(playbackViewModel: playbackViewModel)
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
                playbackViewModel: playbackViewModel,
            )

        case let .playlist(id):
            PlaylistDetailView(
                playlistId: id,
                playbackViewModel: playbackViewModel,
            )

        case let .searchTracks(ids):
            SearchAllTracksView(
                trackIds: ids,
                playbackViewModel: playbackViewModel,
            )
        }
    }
}
