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

    @EnvironmentObject var windowState: WindowState

    @State private var session: SpotifySession
    @State private var trackViewModel = TrackLookupViewModel()
    private let playbackViewModel = PlaybackViewModel.shared

    // Normalized state store
    @State private var store = AppStore()

    // Services - initialized lazily via computed properties
    private var trackService: TrackService { TrackService(store: store) }
    private var playlistService: PlaylistService { PlaylistService(store: store) }
    private var albumService: AlbumService { AlbumService(store: store) }
    private var artistService: ArtistService { ArtistService(store: store) }
    private var deviceService: DeviceService { DeviceService(store: store) }
    private var queueService: QueueService { QueueService(store: store) }
    private var recentlyPlayedService: RecentlyPlayedService { RecentlyPlayedService(store: store) }
    private var searchService: SearchService { SearchService(store: store) }

    @State private var navigationCoordinator = NavigationCoordinator()

    init(authResult: SpotifyAuthResult, onLogout: @escaping () -> Void) {
        self.authResult = authResult
        self.onLogout = onLogout
        _session = State(initialValue: SpotifySession(authResult: authResult))
    }

    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var searchText = ""
    @State private var searchFieldFocused = false

    // Selection state for library detail views (ID-based)
    @State private var selectedAlbumId: String?
    @State private var selectedArtistId: String?
    @State private var selectedPlaylistId: String?

    // Selection state for startpage "show all recent tracks"
    @State private var showingAllRecentTracks = false

    // Determines if we need three-column layout
    private var needsThreeColumnLayout: Bool {
        switch selectedNavigationItem {
        case .albums, .artists, .playlists:
            // Always use three-column for library sections (first item is auto-selected)
            true
        case .startpage:
            showingAllRecentTracks
        case .searchResults:
            searchService.selectedTrack != nil || searchService.selectedAlbum != nil ||
                searchService.selectedArtist != nil || searchService.selectedPlaylist != nil ||
                searchService.showingAllTracks
        case .artistContext:
            navigationCoordinator.currentAlbum != nil
        default:
            false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !windowState.isMiniPlayerMode {
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
                    .searchable(text: $searchText, isPresented: $searchFieldFocused)
                    .onSubmit(of: .search) {
                        Task {
                            await searchService.search(accessToken: authResult.accessToken, query: searchText)
                            if searchService.searchResults != nil {
                                selectedNavigationItem = .searchResults
                            }
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            searchService.clearSearch()
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
                    .searchable(text: $searchText, isPresented: $searchFieldFocused)
                    .onSubmit(of: .search) {
                        Task {
                            await searchService.search(accessToken: authResult.accessToken, query: searchText)
                            if searchService.searchResults != nil {
                                selectedNavigationItem = .searchResults
                            }
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        if newValue.isEmpty {
                            searchService.clearSearch()
                            if selectedNavigationItem == .searchResults {
                                selectedNavigationItem = .startpage
                            }
                        }
                    }
                }
            }

            // Now Playing Bar (always visible at bottom)
            NowPlayingBarView(
                playbackViewModel: playbackViewModel,
                windowState: windowState,
            )
        }
        .background(windowState.isMiniPlayerMode ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .searchShortcuts(searchFieldFocused: $searchFieldFocused)
        .environment(session)
        .environment(deviceService)
        .environment(queueService)
        .environment(recentlyPlayedService)
        .environment(searchService)
        .environment(navigationCoordinator)
        .environment(store)
        .environment(trackService)
        .environment(playlistService)
        .environment(albumService)
        .environment(artistService)
        .focusedValue(\.navigationSelection, $selectedNavigationItem)
        .focusedValue(\.searchFieldFocused, $searchFieldFocused)
        .focusedValue(\.accessToken, session.accessToken)
        .focusedValue(\.recentlyPlayedService, recentlyPlayedService)
        .task {
            // Load favorite track IDs on startup so heart indicators work everywhere
            try? await trackService.loadFavorites(accessToken: session.accessToken)
        }
        .onChange(of: navigationCoordinator.navigationVersion) { _, _ in
            handleNavigation()
        }
        .onChange(of: selectedNavigationItem) { oldValue, newValue in
            // Clear artist context when navigating away from artist section
            if case .artistContext = oldValue {
                if case .artistContext = newValue {
                    // Staying in artist context, don't clear
                } else {
                    // Navigating away, clear the context
                    navigationCoordinator.clearArtistContext()
                }
            }

            // Clear pending playlist when navigating away from playlists
            if oldValue == .playlists, newValue != .playlists {
                navigationCoordinator.pendingPlaylist = nil
            }
        }
        .onChange(of: selectedPlaylistId) { _, newValue in
            // Clear pending playlist when user selects a playlist from the list
            if newValue != nil {
                navigationCoordinator.pendingPlaylist = nil
            }
        }
    }

    /// Handle navigation from the NavigationCoordinator
    private func handleNavigation() {
        // Handle pending playlist navigation
        if navigationCoordinator.pendingPlaylist != nil {
            // Clear other selections
            selectedAlbumId = nil
            selectedArtistId = nil
            selectedPlaylistId = nil
            showingAllRecentTracks = false
            searchService.clearSelection()

            selectedNavigationItem = .playlists
            // The playlist will be shown via navigationCoordinator.pendingPlaylist
            // It stays set until user selects something else
            return
        }

        // Handle pending direct navigation (e.g., navigate to queue)
        if let pendingItem = navigationCoordinator.pendingNavigationItem {
            selectedNavigationItem = pendingItem
            navigationCoordinator.pendingNavigationItem = nil
            return
        }

        // Handle artist context navigation
        guard navigationCoordinator.isInArtistContext else { return }

        // Clear other selections to avoid conflicts
        selectedAlbumId = nil
        selectedArtistId = nil
        selectedPlaylistId = nil
        showingAllRecentTracks = false
        searchService.clearSelection()

        // Navigate to the artist context section
        if let artistItem = navigationCoordinator.artistContextItem {
            selectedNavigationItem = artistItem
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
            hasSearchResults: searchService.searchResults != nil,
            artistContextItem: navigationCoordinator.artistContextItem,
        )
    }

    @ViewBuilder
    private func contentView() -> some View {
        Group {
            if selectedNavigationItem == .searchResults,
               let searchResults = searchService.searchResults
            {
                // Show search results when Search Results is selected
                SearchResultsView(searchResults: searchResults)
                    .navigationTitle("nav.search_results")
            } else {
                // Show main views for other sections
                Group {
                    switch selectedNavigationItem {
                    case .startpage:
                        StartpageView(
                            trackViewModel: trackViewModel,
                            playbackViewModel: playbackViewModel,
                            showingAllRecentTracks: $showingAllRecentTracks,
                        )
                        .navigationTitle("nav.startpage")

                    case .favorites:
                        FavoritesListView(
                            playbackViewModel: playbackViewModel,
                        )
                        .navigationTitle("nav.favorites")

                    case .playlists:
                        PlaylistsListView(
                            playbackViewModel: playbackViewModel,
                            selectedPlaylistId: $selectedPlaylistId,
                        )
                        .navigationTitle("nav.playlists")

                    case .albums:
                        AlbumsListView(
                            playbackViewModel: playbackViewModel,
                            selectedAlbumId: $selectedAlbumId,
                        )
                        .navigationTitle("nav.albums")

                    case .artists:
                        ArtistsListView(
                            playbackViewModel: playbackViewModel,
                            selectedArtistId: $selectedArtistId,
                        )
                        .navigationTitle("nav.artists")

                    case .queue:
                        QueueListView(playbackViewModel: playbackViewModel)
                            .navigationTitle("nav.queue")

                    case .devices:
                        DevicesView()
                            .navigationTitle("nav.devices")

                    case .searchResults:
                        // Handled in outer if statement
                        EmptyView()

                    case .artistContext:
                        // In two-column mode: this is shown as detail
                        // In three-column mode: this is shown as content
                        // Either way, show the artist
                        if let artist = navigationCoordinator.currentArtist {
                            ArtistDetailView(
                                artist: artist,
                                playbackViewModel: playbackViewModel,
                            )
                            .navigationTitle(artist.name)
                        } else {
                            ProgressView()
                        }

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
                if searchService.showingAllTracks,
                   let searchResults = searchService.searchResults
                {
                    SearchTracksDetailView(
                        tracks: searchResults.tracks,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedTrack = searchService.selectedTrack {
                    TrackDetailView(
                        track: selectedTrack,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedAlbum = searchService.selectedAlbum {
                    AlbumDetailView(
                        album: selectedAlbum,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedArtist = searchService.selectedArtist {
                    ArtistDetailView(
                        artist: selectedArtist,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedPlaylist = searchService.selectedPlaylist {
                    PlaylistDetailView(
                        playlist: selectedPlaylist,
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
                    if let albumId = selectedAlbumId,
                       let album = store.albums[albumId]
                    {
                        AlbumDetailView(
                            album: SearchAlbum(from: album),
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_album")
                            .foregroundStyle(.secondary)
                    }

                case .artists:
                    if let artistId = selectedArtistId,
                       let artist = store.artists[artistId]
                    {
                        ArtistDetailView(
                            artist: SearchArtist(from: artist),
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_artist")
                            .foregroundStyle(.secondary)
                    }

                case .playlists:
                    if let pendingPlaylist = navigationCoordinator.pendingPlaylist {
                        PlaylistDetailView(
                            playlist: pendingPlaylist,
                            playbackViewModel: playbackViewModel,
                        )
                    } else if let playlistId = selectedPlaylistId,
                              let playlist = store.playlists[playlistId]
                    {
                        PlaylistDetailView(
                            playlist: SearchPlaylist(from: playlist),
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        Text("empty.select_playlist")
                            .foregroundStyle(.secondary)
                    }

                case .startpage:
                    // Show all recent tracks detail if selected
                    if showingAllRecentTracks {
                        RecentTracksDetailView(
                            tracks: recentlyPlayedService.recentTracks,
                            playbackViewModel: playbackViewModel,
                        )
                    } else {
                        EmptyView()
                    }

                case .artistContext:
                    // Only called in three-column mode (when album is selected)
                    if let album = navigationCoordinator.currentAlbum {
                        AlbumDetailView(
                            album: album,
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
