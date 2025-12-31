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
    @State private var recentlyPlayedViewModel = RecentlyPlayedViewModel()
    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var isMiniPlayerMode = false
    @State private var searchText = ""

    // Selection state for detail views
    @State private var selectedAlbum: AlbumSimplified?
    @State private var selectedArtist: ArtistSimplified?
    @State private var selectedPlaylist: PlaylistSimplified?

    // Selection state for recently played items from startpage
    @State private var selectedRecentAlbum: SearchAlbum?
    @State private var selectedRecentArtist: SearchArtist?
    @State private var selectedRecentPlaylist: SearchPlaylist?
    @State private var showingAllRecentTracks = false

    // Determines if we need three-column layout (when something is selected)
    private var needsThreeColumnLayout: Bool {
        switch selectedNavigationItem {
        case .albums:
            selectedAlbum != nil
        case .artists:
            selectedArtist != nil
        case .playlists:
            selectedPlaylist != nil
        case .startpage:
            selectedRecentAlbum != nil || selectedRecentArtist != nil || selectedRecentPlaylist != nil || showingAllRecentTracks
        case .searchResults:
            searchViewModel.selectedTrack != nil || searchViewModel.selectedAlbum != nil ||
                searchViewModel.selectedArtist != nil || searchViewModel.selectedPlaylist != nil ||
                searchViewModel.showingAllTracks
        default:
            false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isMiniPlayerMode {
                if needsThreeColumnLayout {
                    // Three-column layout: sidebar + content + detail
                    NavigationSplitView {
                        sidebarView()
                    } content: {
                        contentView()
                            .navigationSplitViewColumnWidth(min: 300, ideal: 450, max: 600)
                    } detail: {
                        detailView()
                    }
                    .navigationSplitViewStyle(.automatic)
                    .searchable(text: $searchText)
                    .onSubmit(of: .search) {
                        Task {
                            await searchViewModel.search(accessToken: authResult.accessToken, query: searchText)
                            if searchViewModel.searchResults != nil {
                                selectedNavigationItem = .searchResults
                            }
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            searchViewModel.clearSearch()
                            if selectedNavigationItem == .searchResults {
                                selectedNavigationItem = .startpage
                            }
                        }
                    }
                } else {
                    // Two-column layout: sidebar + detail (content spans full width)
                    NavigationSplitView {
                        sidebarView()
                    } detail: {
                        contentView()
                    }
                    .navigationSplitViewStyle(.automatic)
                    .searchable(text: $searchText)
                    .onSubmit(of: .search) {
                        Task {
                            await searchViewModel.search(accessToken: authResult.accessToken, query: searchText)
                            if searchViewModel.searchResults != nil {
                                selectedNavigationItem = .searchResults
                            }
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            searchViewModel.clearSearch()
                            if selectedNavigationItem == .searchResults {
                                selectedNavigationItem = .startpage
                            }
                        }
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

    // MARK: - View Builders

    @ViewBuilder
    private func sidebarView() -> some View {
        SidebarView(
            selection: $selectedNavigationItem,
            onLogout: {
                playbackViewModel.stop()
                onLogout()
            },
            hasSearchResults: searchViewModel.searchResults != nil,
        )
    }

    @ViewBuilder
    private func contentView() -> some View {
        Group {
            if selectedNavigationItem == .searchResults,
               let searchResults = searchViewModel.searchResults
            {
                // Show search results when Search Results is selected
                SearchResultsView(
                    searchResults: searchResults,
                    searchViewModel: searchViewModel,
                )
                .navigationTitle("nav.search_results")
            } else {
                // Show main views for other sections
                Group {
                    switch selectedNavigationItem {
                    case .startpage:
                        StartpageView(
                            authResult: authResult,
                            trackViewModel: trackViewModel,
                            playbackViewModel: playbackViewModel,
                            recentlyPlayedViewModel: recentlyPlayedViewModel,
                            selectedRecentAlbum: $selectedRecentAlbum,
                            selectedRecentArtist: $selectedRecentArtist,
                            selectedRecentPlaylist: $selectedRecentPlaylist,
                            showingAllRecentTracks: $showingAllRecentTracks,
                        )
                        .navigationTitle("nav.startpage")

                    case .favorites:
                        FavoritesListView(
                            authResult: authResult,
                            favoritesViewModel: favoritesViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("nav.favorites")

                    case .playlists:
                        PlaylistsListView(
                            authResult: authResult,
                            playlistsViewModel: playlistsViewModel,
                            playbackViewModel: playbackViewModel,
                            selectedPlaylist: $selectedPlaylist,
                        )
                        .navigationTitle("nav.playlists")

                    case .albums:
                        AlbumsListView(
                            authResult: authResult,
                            albumsViewModel: albumsViewModel,
                            playbackViewModel: playbackViewModel,
                            selectedAlbum: $selectedAlbum,
                        )
                        .navigationTitle("nav.albums")

                    case .artists:
                        ArtistsListView(
                            authResult: authResult,
                            artistsViewModel: artistsViewModel,
                            playbackViewModel: playbackViewModel,
                            selectedArtist: $selectedArtist,
                        )
                        .navigationTitle("nav.artists")

                    case .queue:
                        QueueListView(
                            authResult: authResult,
                            queueViewModel: queueViewModel,
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("nav.queue")

                    case .searchResults:
                        // Handled in outer if statement
                        EmptyView()

                    case .none:
                        Text("empty.select_item")
                            .foregroundStyle(.secondary)
                    }
                }
                .playbackShortcuts(playbackViewModel: playbackViewModel)
                .libraryNavigationShortcuts(selection: $selectedNavigationItem)
            }
        }
    }

    @ViewBuilder
    private func detailView() -> some View {
        Group {
            if selectedNavigationItem == .searchResults {
                // When viewing search results: show search result details
                if searchViewModel.showingAllTracks,
                   let searchResults = searchViewModel.searchResults
                {
                    SearchTracksDetailView(
                        tracks: searchResults.tracks,
                        authResult: authResult,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedTrack = searchViewModel.selectedTrack {
                    TrackDetailView(
                        track: selectedTrack,
                        authResult: authResult,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedAlbum = searchViewModel.selectedAlbum {
                    AlbumDetailView(
                        album: selectedAlbum,
                        authResult: authResult,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedArtist = searchViewModel.selectedArtist {
                    ArtistDetailView(
                        artist: selectedArtist,
                        authResult: authResult,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedPlaylist = searchViewModel.selectedPlaylist {
                    PlaylistDetailView(
                        playlist: selectedPlaylist,
                        authResult: authResult,
                        playbackViewModel: playbackViewModel,
                    )
                } else {
                    Text("empty.select_search_result")
                        .foregroundStyle(.secondary)
                }
            } else {
                // When not searching: show details for library selections
                switch selectedNavigationItem {
                case .albums:
                    if let selectedAlbum {
                        AlbumDetailView(
                            album: SearchAlbum(from: selectedAlbum),
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_album")
                            .foregroundStyle(.secondary)
                    }

                case .artists:
                    if let selectedArtist {
                        ArtistDetailView(
                            artist: SearchArtist(from: selectedArtist),
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_artist")
                            .foregroundStyle(.secondary)
                    }

                case .playlists:
                    if let selectedPlaylist {
                        PlaylistDetailView(
                            playlist: SearchPlaylist(from: selectedPlaylist),
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_playlist")
                            .foregroundStyle(.secondary)
                    }

                case .startpage:
                    // Show details for recently played selections
                    if showingAllRecentTracks {
                        RecentTracksDetailView(
                            tracks: recentlyPlayedViewModel.recentTracks,
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else if let selectedAlbum = selectedRecentAlbum {
                        AlbumDetailView(
                            album: selectedAlbum,
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else if let selectedArtist = selectedRecentArtist {
                        ArtistDetailView(
                            artist: selectedArtist,
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else if let selectedPlaylist = selectedRecentPlaylist {
                        PlaylistDetailView(
                            playlist: selectedPlaylist,
                            authResult: authResult,
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        EmptyView()
                    }

                default:
                    // For Favorites, Queue, etc.: no detail view
                    EmptyView()
                }
            }
        }
    }
}
