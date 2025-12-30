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
    @State private var playlistsViewModel = PlaylistsViewModel()
    @State private var selectedNavigationItem: NavigationItem? = .startpage

    var body: some View {
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

                case .playlists:
                    PlaylistsListView(
                        authResult: authResult,
                        playlistsViewModel: playlistsViewModel,
                        playbackViewModel: playbackViewModel,
                    )
                    .navigationTitle("Playlists")

                case .none:
                    Text("Select an item from the sidebar")
                        .foregroundStyle(.secondary)
                }
            }
            .playbackShortcuts(playbackViewModel: playbackViewModel)
        }
    }
}
