//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import SwiftUI

// MARK: - LoggedInView

struct LoggedInView: View {
    let authResult: SpotifyAuthResult
    let onLogout: () -> Void

    @EnvironmentObject var windowState: WindowState

    @State private var session: SpotifySession
    private let playbackViewModel = PlaybackViewModel.shared

    // Normalized state store
    @State private var store: AppStore

    // Services that need Task deduplication or subscription persistence
    @State private var playlistService: PlaylistService
    @State private var albumService: AlbumService
    @State private var artistService: ArtistService
    @State private var queueService: QueueService
    @State private var connectionService: ConnectionService

    // Services - stateless, created on demand (all state lives in AppStore)
    private var trackService: TrackService { TrackService(store: store) }
    private var deviceService: DeviceService { DeviceService(store: store) }
    private var recentlyPlayedService: RecentlyPlayedService { RecentlyPlayedService(store: store) }
    private var searchService: SearchService { SearchService(store: store) }
    private var topItemsService: TopItemsService { TopItemsService(store: store) }
    private var newReleasesService: NewReleasesService { NewReleasesService(store: store) }

    @State private var navigationCoordinator = NavigationCoordinator()

    init(authResult: SpotifyAuthResult, onLogout: @escaping () -> Void) {
        self.authResult = authResult
        self.onLogout = onLogout

        let store = AppStore()
        let session = SpotifySession(authResult: authResult)
        _store = State(initialValue: store)
        _session = State(initialValue: session)

        // Initialize services that need Task deduplication or subscription persistence
        _playlistService = State(initialValue: PlaylistService(store: store))
        _albumService = State(initialValue: AlbumService(store: store))
        _artistService = State(initialValue: ArtistService(store: store))
        _queueService = State(initialValue: QueueService(store: store, tokenProvider: {
            await session.validAccessToken()
        }))
        _connectionService = State(initialValue: ConnectionService(store: store))

        // Give PlaybackViewModel access to AppStore for reading current track metadata
        playbackViewModel.setStore(store)
    }

    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var searchText = ""
    @State private var searchFieldFocused = false

    // Selection state for library detail views (ID-based)
    @State private var selectedAlbumId: String?
    @State private var selectedArtistId: String?
    @State private var selectedPlaylistId: String?

    // Sidebar width for dynamic now playing bar positioning
    @State private var sidebarWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Determines if we need three-column layout
    private var needsThreeColumnLayout: Bool {
        switch selectedNavigationItem {
        case .albums, .artists, .playlists:
            // Always use three-column for library sections (first item is auto-selected)
            true
        default:
            false
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !windowState.isMiniPlayerMode {
                mainLayoutView
            }

            // Now Playing Bar - floats over content, dynamically positioned to clear sidebar
            NowPlayingBarView(
                playbackViewModel: playbackViewModel,
                windowState: windowState,
            )
            .padding(.leading, windowState.isMiniPlayerMode ? 0 : (columnVisibility == .detailOnly ? 0 : sidebarWidth + 8))
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
            #if DEBUG
                // Set debug references to actual @State stored instances
                AppStore.current = store
                SpotifySession.current = session
            #endif

            // Load startup data
            let token = await session.validAccessToken()

            // Load user ID first (needed for playlist ownership checks)
            await session.loadUserIdIfNeeded()

            // Load favorites so heart indicators work everywhere
            async let favorites: () = { try? await trackService.loadFavorites(accessToken: token) }()

            // Load startpage data (top artists, new releases, recently played)
            async let topArtists: () = topItemsService.loadTopArtists(accessToken: token)
            async let newReleases: () = newReleasesService.loadNewReleases(accessToken: token)
            async let recentlyPlayed: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)

            _ = await (favorites, topArtists, newReleases, recentlyPlayed)

            // Load user ID for player authentication
            await session.loadUserIdIfNeeded()

            // Set providers for automatic reinitialization on session disconnect
            playbackViewModel.setProviders(
                tokenProvider: { await session.validAccessToken() },
                usernameProvider: { await MainActor.run { session.userId } }
            )

            // Initialize player/Spirc so Spotifly appears as a Connect device
            if let userId = session.userId {
                await playbackViewModel.initializeIfNeeded(accessToken: token, username: userId)
            }

            #if DEBUG
            // AUTO-PLAY TEST: Play a track 3 seconds after launch to test playback
            Task {
                try? await Task.sleep(for: .seconds(3))
                debugLog("TEST", "Auto-play test starting...")
                let testToken = await session.validAccessToken()
                // Play "Never Gonna Give You Up" by Rick Astley as a test track
                await playbackViewModel.play(uriOrUrl: "spotify:track:4PTG3Z6ehGkBFwjybzWkR8", accessToken: testToken)
                debugLog("TEST", "Auto-play test initiated")
            }
            #endif
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

            // Clear ephemeral viewing state when navigating away from albums/artists
            if oldValue == .albums, newValue != .albums {
                navigationCoordinator.viewingAlbumId = nil
            }
            if oldValue == .artists, newValue != .artists {
                navigationCoordinator.viewingArtistId = nil
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
        Group {
            if needsThreeColumnLayout {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } content: {
                    contentView()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 450, max: 600)
                } detail: {
                    detailView()
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } detail: {
                    contentView()
                }
            }
        }
        .navigationSplitViewStyle(.automatic)
        .searchable(text: $searchText, isPresented: $searchFieldFocused)
        .onSubmit(of: .search) { performSearch() }
        .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
        .toolbar { refreshToolbarItem }
    }

    @ToolbarContentBuilder
    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if canRefreshCurrentSection {
                Button {
                    Task { await refreshCurrentSection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        ToolbarItem(placement: .navigation) {
            if selectedNavigationItem == .queue {
                Button {
                    NotificationCenter.default.post(name: .scrollToCurrentTrack, object: nil)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Scroll to Current Track")
            }
        }
        ToolbarItem(placement: .navigation) {
            contextMenu
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenu: some View {
        switch selectedNavigationItem {
        case .albums:
            if let albumId = selectedAlbumId, let album = store.albums[albumId] {
                albumContextMenu(album: album)
            }
        case .artists:
            if let artistId = selectedArtistId, let artist = store.artists[artistId] {
                artistContextMenu(artist: artist)
            }
        case .playlists:
            if let playlistId = selectedPlaylistId, let playlist = store.playlists[playlistId] {
                playlistContextMenu(playlist: playlist)
            }
        default:
            EmptyView()
        }
    }

    private func albumContextMenu(album: Album) -> some View {
        let isInLibrary = store.userAlbumIds.contains(album.id)

        return Menu {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: album.uri, accessToken: token)
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()

            Button {
                if let externalUrl = album.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(album.externalUrl == nil)

            Divider()

            if isInLibrary {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showAlbumRemoveConfirmation, object: album.id)
                } label: {
                    Label("Remove from Library", systemImage: "minus.circle")
                }
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await albumService.saveAlbumToLibrary(albumId: album.id, accessToken: token)
                    }
                } label: {
                    Label("Add to Library", systemImage: "plus.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    private func artistContextMenu(artist: Artist) -> some View {
        let isFollowing = store.userArtistIds.contains(artist.id)

        return Menu {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: artist.uri, accessToken: token)
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()

            Button {
                if let externalUrl = artist.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(artist.externalUrl == nil)

            Divider()

            if isFollowing {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showArtistUnfollowConfirmation, object: artist.id)
                } label: {
                    Label("Unfollow", systemImage: "person.badge.minus")
                }
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await artistService.followArtist(artistId: artist.id, accessToken: token)
                    }
                } label: {
                    Label("Follow", systemImage: "person.badge.plus")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    private func playlistContextMenu(playlist: Playlist) -> some View {
        let isOwner = playlist.ownerId == session.userId
        let isInLibrary = store.userPlaylistIds.contains(playlist.id)

        return Menu {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: playlist.uri, accessToken: token)
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()

            Button {
                if let externalUrl = playlist.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(playlist.externalUrl == nil)

            if isOwner {
                Divider()

                Button {
                    NotificationCenter.default.post(name: .showPlaylistEditDetails, object: playlist.id)
                } label: {
                    Label("Edit Details", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistDeleteConfirmation, object: playlist.id)
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            } else {
                Divider()

                if isInLibrary {
                    Button(role: .destructive) {
                        NotificationCenter.default.post(name: .showPlaylistUnfollowConfirmation, object: playlist.id)
                    } label: {
                        Label("Unfollow Playlist", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        Task {
                            let token = await session.validAccessToken()
                            try? await playlistService.followPlaylist(playlistId: playlist.id, accessToken: token)
                        }
                    } label: {
                        Label("Follow Playlist", systemImage: "plus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    private func performSearch() {
        Task {
            let token = await session.validAccessToken()
            debugLog("Search", "Starting search for: \(searchText)")
            await searchService.search(accessToken: token, query: searchText)
            debugLog("Search", "After search - results: \(store.searchResults != nil), error: \(store.searchErrorMessage ?? "nil")")
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

    /// Handle back navigation from AlbumsListView/ArtistsListView
    private func handleBackNavigation(section: NavigationItem, selectionId: String?) {
        // Clear ephemeral viewing state
        navigationCoordinator.clearEphemeralViewing()

        // Navigate to the previous section
        selectedNavigationItem = section

        // Restore selection if provided
        if let selectionId {
            switch section {
            case .playlists:
                selectedPlaylistId = selectionId
            case .albums:
                selectedAlbumId = selectionId
            case .artists:
                selectedArtistId = selectionId
            default:
                break
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
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task(id: geometry.size.width) {
                        debugLog("SidebarWidth", "Updating sidebarWidth to: \(geometry.size.width)")
                        await MainActor.run {
                            sidebarWidth = geometry.size.width
                        }
                    }
            }
        }
    }

    /// Whether the current section supports refresh
    private var canRefreshCurrentSection: Bool {
        switch selectedNavigationItem {
        case .playlists, .albums, .artists, .favorites, .speakers, .queue:
            true
        default:
            false
        }
    }

    /// Refresh data for the current section (clears store and fetches fresh)
    private func refreshCurrentSection() async {
        let token = await session.validAccessToken()

        switch selectedNavigationItem {
        case .playlists:
            let previousSelection = selectedPlaylistId
            store.playlistsPagination.reset()
            store.setUserPlaylistIds([])
            try? await playlistService.loadUserPlaylists(accessToken: token, forceRefresh: true)
            restoreOrSelectFirst(previous: previousSelection, available: store.userPlaylistIds, selection: &selectedPlaylistId)

        case .albums:
            let previousSelection = selectedAlbumId
            store.albumsPagination.reset()
            store.setUserAlbumIds([])
            try? await albumService.loadUserAlbums(accessToken: token, forceRefresh: true)
            restoreOrSelectFirst(previous: previousSelection, available: store.userAlbumIds, selection: &selectedAlbumId)

        case .artists:
            let previousSelection = selectedArtistId
            store.artistsPagination.reset()
            store.setUserArtistIds([])
            try? await artistService.loadUserArtists(accessToken: token, forceRefresh: true)
            restoreOrSelectFirst(previous: previousSelection, available: store.userArtistIds, selection: &selectedArtistId)

        case .favorites:
            store.favoritesPagination.reset()
            store.setSavedTrackIds([])
            try? await trackService.loadFavorites(accessToken: token, forceRefresh: true)

        case .speakers:
            await deviceService.loadDevices(accessToken: token)

        default:
            break
        }
    }

    /// Restore previous selection if still available, otherwise select first item
    private func restoreOrSelectFirst(previous: String?, available: [String], selection: inout String?) {
        if let previous, available.contains(previous) {
            selection = previous
        } else {
            selection = available.first
        }
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
                                onBack: handleBackNavigation,
                            )
                            .navigationTitle("nav.albums")

                        case .artists:
                            ArtistsListView(
                                playbackViewModel: playbackViewModel,
                                selectedArtistId: $selectedArtistId,
                                onBack: handleBackNavigation,
                            )
                            .navigationTitle("nav.artists")

                        case .queue:
                            QueueListView(playbackViewModel: playbackViewModel)
                                .navigationTitle("nav.queue")

                        case .speakers:
                            SpeakersView(playbackViewModel: playbackViewModel)
                                .navigationTitle("nav.speakers")

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

        case let .searchTracks(tracks):
            SearchAllTracksView(
                tracks: tracks,
                playbackViewModel: playbackViewModel,
            )
        }
    }

    @ViewBuilder
    private func detailView() -> some View {
        Group {
            // Show details for library selections (three-column layout)
            switch selectedNavigationItem {
            case .albums:
                if let albumId = selectedAlbumId,
                   let album = store.albums[albumId]
                {
                    AlbumDetailView(
                        album: album,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(albumId) // Force view recreation when album changes
                } else if let albumId = selectedAlbumId {
                    // Album ID is set but not in store yet - show loading and fetch
                    AlbumDetailView(
                        albumId: albumId,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(albumId)
                } else {
                    Text("empty.select_album")
                        .foregroundStyle(.secondary)
                }

            case .artists:
                if let artistId = selectedArtistId,
                   let artist = store.artists[artistId]
                {
                    ArtistDetailView(
                        artist: artist,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(artistId) // Force view recreation when artist changes
                } else if let artistId = selectedArtistId {
                    // Artist ID is set but not in store yet - show loading and fetch
                    ArtistDetailView(
                        artistId: artistId,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(artistId)
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
                        playlist: playlist,
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
