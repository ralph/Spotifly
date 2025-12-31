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
    @State private var searchViewModel = SearchViewModel()
    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var isMiniPlayerMode = false
    @State private var searchText = ""

    // Selection state for detail views
    @State private var selectedAlbum: AlbumSimplified?
    @State private var selectedArtist: ArtistSimplified?
    @State private var selectedPlaylist: PlaylistSimplified?

    var body: some View {
        VStack(spacing: 0) {
            if !isMiniPlayerMode {
                NavigationSplitView {
                    // Sidebar
                    SidebarView(selection: $selectedNavigationItem, onLogout: {
                        playbackViewModel.stop()
                        onLogout()
                    })
                } content: {
                    // Content column: search results or main views
                    if let searchResults = searchViewModel.searchResults {
                        // Show search results when searching
                        SearchResultsView(
                            searchResults: searchResults,
                            searchViewModel: searchViewModel,
                        )
                        .navigationTitle("Search Results")
                    } else {
                        // Show main views when not searching
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
                                    selectedPlaylist: $selectedPlaylist
                                )
                                .navigationTitle("Playlists")

                            case .albums:
                                AlbumsListView(
                                    authResult: authResult,
                                    albumsViewModel: albumsViewModel,
                                    playbackViewModel: playbackViewModel,
                                    selectedAlbum: $selectedAlbum
                                )
                                .navigationTitle("Albums")

                            case .artists:
                                ArtistsListView(
                                    authResult: authResult,
                                    artistsViewModel: artistsViewModel,
                                    playbackViewModel: playbackViewModel,
                                    selectedArtist: $selectedArtist
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
                } detail: {
                    // Detail column: show details based on context
                    Group {
                        if searchViewModel.searchResults != nil {
                            // When searching: show search result details
                            if let selectedTrack = searchViewModel.selectedTrack {
                                TrackDetailView(
                                    track: selectedTrack,
                                    authResult: authResult,
                                    playbackViewModel: playbackViewModel
                                )
                            } else if let selectedAlbum = searchViewModel.selectedAlbum {
                                AlbumDetailView(
                                    album: selectedAlbum,
                                    authResult: authResult,
                                    playbackViewModel: playbackViewModel
                                )
                            } else if let selectedArtist = searchViewModel.selectedArtist {
                                ArtistDetailView(
                                    artist: selectedArtist,
                                    authResult: authResult,
                                    playbackViewModel: playbackViewModel
                                )
                            } else if let selectedPlaylist = searchViewModel.selectedPlaylist {
                                PlaylistDetailView(
                                    playlist: selectedPlaylist,
                                    authResult: authResult,
                                    playbackViewModel: playbackViewModel
                                )
                            } else {
                                Text("Select a search result to see details")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            // When not searching: show details for library selections
                            switch selectedNavigationItem {
                            case .albums:
                                if let selectedAlbum = selectedAlbum {
                                    AlbumDetailView(
                                        album: SearchAlbum(from: selectedAlbum),
                                        authResult: authResult,
                                        playbackViewModel: playbackViewModel
                                    )
                                } else {
                                    Text("Select an album to see details")
                                        .foregroundStyle(.secondary)
                                }

                            case .artists:
                                if let selectedArtist = selectedArtist {
                                    ArtistDetailView(
                                        artist: SearchArtist(from: selectedArtist),
                                        authResult: authResult,
                                        playbackViewModel: playbackViewModel
                                    )
                                } else {
                                    Text("Select an artist to see details")
                                        .foregroundStyle(.secondary)
                                }

                            case .playlists:
                                if let selectedPlaylist = selectedPlaylist {
                                    PlaylistDetailView(
                                        playlist: SearchPlaylist(from: selectedPlaylist),
                                        authResult: authResult,
                                        playbackViewModel: playbackViewModel
                                    )
                                } else {
                                    Text("Select a playlist to see details")
                                        .foregroundStyle(.secondary)
                                }

                            default:
                                // For Favorites, Queue, Startpage, etc.: no detail view
                                EmptyView()
                            }
                        }
                    }
                }
                .searchable(text: $searchText)
                .onSubmit(of: .search) {
                    Task {
                        await searchViewModel.search(accessToken: authResult.accessToken, query: searchText)
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        searchViewModel.clearSearch()
                    }
                }
            }

            // Now Playing Bar (always visible at bottom)
            NowPlayingBarView(
                authResult: authResult,
                playbackViewModel: playbackViewModel,
                isMiniPlayerMode: $isMiniPlayerMode,
            )
        }
        .onChange(of: isMiniPlayerMode) { _, newValue in
            resizeWindow(miniMode: newValue)
        }
    }

    private func resizeWindow(miniMode: Bool) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }

        if miniMode {
            // Mini mode: resize to compact size
            window.setContentSize(NSSize(width: 600, height: 120))
        } else {
            // Normal mode: resize to default size
            window.setContentSize(NSSize(width: 800, height: 600))
        }
    }
}
