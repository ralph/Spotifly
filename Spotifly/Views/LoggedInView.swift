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
    private let playbackViewModel = PlaybackViewModel.shared

    // Normalized state store
    @State private var store = AppStore()

    // Services - stateless, created on demand (all state lives in AppStore)
    private var trackService: TrackService { TrackService(store: store) }
    private var playlistService: PlaylistService { PlaylistService(store: store) }
    private var albumService: AlbumService { AlbumService(store: store) }
    private var artistService: ArtistService { ArtistService(store: store) }
    private var deviceService: DeviceService { DeviceService(store: store) }
    private var queueService: QueueService { QueueService(store: store) }
    private var recentlyPlayedService: RecentlyPlayedService { RecentlyPlayedService(store: store) }
    private var searchService: SearchService { SearchService(store: store) }
    private var topItemsService: TopItemsService { TopItemsService(store: store) }
    private var newReleasesService: NewReleasesService { NewReleasesService(store: store) }

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

    // Determines if we need three-column layout
    private var needsThreeColumnLayout: Bool {
        switch selectedNavigationItem {
        case .albums, .artists, .playlists:
            // Always use three-column for library sections (first item is auto-selected)
            true
        case .searchResults:
            store.hasSearchSelection
        default:
            false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !windowState.isMiniPlayerMode {
                mainLayoutView
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
        .environment(topItemsService)
        .environment(newReleasesService)
        .environment(navigationCoordinator)
        .environment(store)
        .environment(trackService)
        .environment(playlistService)
        .environment(albumService)
        .environment(artistService)
        .focusedValue(\.navigationSelection, $selectedNavigationItem)
        .focusedValue(\.searchFieldFocused, $searchFieldFocused)
        .focusedValue(\.session, session)
        .focusedValue(\.recentlyPlayedService, recentlyPlayedService)
        .task {
            // Load startup data
            let token = await session.validAccessToken()

            // Load favorites so heart indicators work everywhere
            async let favorites: () = { try? await trackService.loadFavorites(accessToken: token) }()

            // Load startpage data (top artists, new releases, recently played)
            async let topArtists: () = topItemsService.loadTopArtists(accessToken: token)
            async let newReleases: () = newReleasesService.loadNewReleases(accessToken: token)
            async let recentlyPlayed: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)

            _ = await (favorites, topArtists, newReleases, recentlyPlayed)
        }
        .onChange(of: navigationCoordinator.pendingNavigationItem) { _, newValue in
            if let pendingItem = newValue {
                selectedNavigationItem = pendingItem
                navigationCoordinator.pendingNavigationItem = nil
            }
        }
        .onChange(of: navigationCoordinator.pendingPlaylist) { _, newValue in
            if newValue != nil {
                // Clear other selections and navigate to playlists
                selectedAlbumId = nil
                selectedArtistId = nil
                selectedPlaylistId = nil
                store.clearSearchSelection()
                selectedNavigationItem = .playlists
            }
        }
        .onChange(of: selectedNavigationItem) { oldValue, newValue in
            // Clear navigation stack when switching sidebar sections
            navigationCoordinator.clearNavigationStack()

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

    // MARK: - View Builders

    @ViewBuilder
    private var mainLayoutView: some View {
        if needsThreeColumnLayout {
            threeColumnLayout
        } else {
            twoColumnLayout
        }
    }

    @ViewBuilder
    private var threeColumnLayout: some View {
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
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
    }

    @ViewBuilder
    private var twoColumnLayout: some View {
        NavigationSplitView {
            sidebarView()
        } detail: {
            contentView()
        }
        .navigationSplitViewStyle(.automatic)
        .searchable(text: $searchText, isPresented: $searchFieldFocused)
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
    }

    private func performSearch() {
        Task {
            let token = await session.validAccessToken()
            await searchService.search(accessToken: token, query: searchText)
            if store.searchResults != nil {
                selectedNavigationItem = .searchResults
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        if newValue.isEmpty {
            store.clearSearch()
            if selectedNavigationItem == .searchResults {
                selectedNavigationItem = .startpage
            }
        }
    }

    @ViewBuilder
    private func sidebarView() -> some View {
        SidebarView(
            selection: $selectedNavigationItem,
            onLogout: {
                playbackViewModel.stop()
                onLogout()
            },
            hasSearchResults: store.searchResults != nil,
        )
    }

    @ViewBuilder
    private func contentView() -> some View {
        NavigationStack(path: $navigationCoordinator.navigationPath) {
            Group {
                if selectedNavigationItem == .searchResults,
                   let searchResults = store.searchResults
                {
                    // Show search results when Search Results is selected
                    SearchResultsView(searchResults: searchResults, playbackViewModel: playbackViewModel)
                        .navigationTitle("nav.search_results")
                } else {
                    // Show main views for other sections
                    Group {
                        switch selectedNavigationItem {
                        case .startpage:
                            StartpageView()
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

                        case .none:
                            Text("empty.select_item")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .playbackShortcuts(playbackViewModel: playbackViewModel)
                    .libraryNavigationShortcuts(selection: $selectedNavigationItem)
                }
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                destinationView(for: destination)
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
        switch destination {
        case let .artist(id):
            ArtistDetailView(
                artistId: id,
                playbackViewModel: playbackViewModel,
            )

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
        }
    }

    @ViewBuilder
    private func detailView() -> some View {
        Group {
            if selectedNavigationItem == .searchResults {
                // When viewing search results: show search result details
                if store.showingAllSearchTracks,
                   let searchResults = store.searchResults
                {
                    SearchTracksDetailView(
                        tracks: searchResults.tracks,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedTrack = store.selectedSearchTrack {
                    TrackDetailView(
                        track: selectedTrack,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedAlbum = store.selectedSearchAlbum {
                    AlbumDetailView(
                        album: selectedAlbum,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedArtist = store.selectedSearchArtist {
                    ArtistDetailView(
                        artist: selectedArtist,
                        playbackViewModel: playbackViewModel,
                    )
                } else if let selectedPlaylist = store.selectedSearchPlaylist {
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

                default:
                    // For Favorites, Queue, etc.: no detail view
                    EmptyView()
                }
            }
        }
    }
}
