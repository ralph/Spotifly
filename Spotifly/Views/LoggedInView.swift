//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct LoggedInView: View {
    let authResult: SpotifyAuthResult
    let onLogout: () -> Void

    @State private var trackViewModel = TrackLookupViewModel()
    @State private var playbackViewModel = PlaybackViewModel()
    @State private var favoritesViewModel = FavoritesViewModel()
    @State private var playlistsViewModel = PlaylistsViewModel()
    @State private var albumsViewModel = AlbumsViewModel()
    @State private var artistsViewModel = ArtistsViewModel()
    @State private var queueViewModel = QueueViewModel()
    @State private var selectedNavigationItem: NavigationItem? = .startpage

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(selection: $selectedNavigationItem, onLogout: {
                    playbackViewModel.stop()
                    onLogout()
                })
            } detail: {
                Group {
                    switch selectedNavigationItem {
                    case .startpage:
                        StartpageView(
                            authResult: authResult,
                            trackViewModel: trackViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Startpage")

                    case .favorites:
                        FavoritesListView(
                            authResult: authResult,
                            favoritesViewModel: favoritesViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Favorites")

                    case .playlists:
                        PlaylistsListView(
                            authResult: authResult,
                            playlistsViewModel: playlistsViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Playlists")

                    case .albums:
                        AlbumsListView(
                            authResult: authResult,
                            albumsViewModel: albumsViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Albums")

                    case .artists:
                        ArtistsListView(
                            authResult: authResult,
                            artistsViewModel: artistsViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Artists")

                    case .queue:
                        QueueListView(
                            authResult: authResult,
                            queueViewModel: queueViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("Queue")

                    case .none:
                        Text("Select an item from the sidebar")
                            .foregroundStyle(.secondary)
                    }
                }
                .playbackShortcuts(playbackViewModel: playbackViewModel)
                .libraryNavigationShortcuts(selection: $selectedNavigationItem)
            }

            // Now Playing Bar (always visible at bottom)
            NowPlayingBarView(
                authResult: authResult,
                playbackViewModel: playbackViewModel,
            )
        }
    }
}
