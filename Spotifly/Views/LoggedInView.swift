//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
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
    @State private var isMiniPlayerMode = false

    var body: some View {
        VStack(spacing: 0) {
            if !isMiniPlayerMode {
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
            }

            // Now Playing Bar (always visible at bottom)
            NowPlayingBarView(
                authResult: authResult,
                playbackViewModel: playbackViewModel,
                isMiniPlayerMode: $isMiniPlayerMode
            )
        }
        .frame(
            minWidth: isMiniPlayerMode ? 400 : 500,
            idealWidth: isMiniPlayerMode ? 400 : 800,
            maxWidth: isMiniPlayerMode ? 400 : .infinity,
            minHeight: isMiniPlayerMode ? 66 : 400
        )
        .onChange(of: isMiniPlayerMode) { _, newValue in
            resizeWindow(miniMode: newValue)
        }
    }

    private func resizeWindow(miniMode: Bool) {
        guard let window = NSApplication.shared.windows.first else { return }

        if miniMode {
            // Mini mode: shrink to compact width
            let newSize = NSSize(width: 400, height: 66)
            window.setContentSize(newSize)
            window.styleMask.remove(.resizable)
        } else {
            // Restore mode: return to normal size
            let newSize = NSSize(width: 800, height: 600)
            window.setContentSize(newSize)
            window.styleMask.insert(.resizable)
        }
    }
}
