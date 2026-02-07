//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import Combine
import SwiftUI

// MARK: - LoggedInView

struct LoggedInView: View {
    let authResult: SpotifyAuthResult
    let onLogout: () -> Void

    @EnvironmentObject var windowState: WindowState

    @State private var session: SpotifySession
    private let playbackViewModel = PlaybackViewModel.shared

    /// Normalized state store
    @State private var store: AppStore

    // Services that need Task deduplication or subscription persistence
    @State private var playlistService: PlaylistService
    @State private var albumService: AlbumService
    @State private var artistService: ArtistService
    @State private var queueService: QueueService
    @State private var connectionService: ConnectionService
    @State private var deviceService: DeviceService

    /// Services - stateless, created on demand (all state lives in AppStore)
    private var trackService: TrackService {
        TrackService(store: store)
    }

    private var recentlyPlayedService: RecentlyPlayedService {
        RecentlyPlayedService(store: store)
    }

    private var searchService: SearchService {
        SearchService(store: store)
    }

    private var topItemsService: TopItemsService {
        TopItemsService(store: store)
    }

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
        _deviceService = State(initialValue: DeviceService(store: store))

        // Give PlaybackViewModel access to AppStore for reading current track metadata
        playbackViewModel.setStore(store)
    }

    @AppStorage("topItemsTimeRange") private var topItemsTimeRange: String = TopItemsTimeRange.mediumTerm.rawValue

    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var searchText = ""
    @State private var searchFieldFocused = false

    // Selection state for library detail views (ID-based)
    @State private var selectedAlbumId: String?
    @State private var selectedArtistId: String?
    @State private var selectedPlaylistId: String?

    /// Blocking state shown instead of the main app
    enum BlockingState {
        case premiumRequired
        case userNotWhitelisted
    }

    @State private var blockingState: BlockingState?

    // Sidebar width for dynamic now playing bar positioning
    @State private var sidebarWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Determines if we need three-column layout
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
        switch blockingState {
        case .premiumRequired:
            PremiumRequiredView(
                displayName: store.userProfile?.displayName,
                onLogout: onLogout,
            )
            .frame(minWidth: 500, minHeight: 400)
        case .userNotWhitelisted:
            UserNotWhitelistedView(
                clientId: SpotifyConfig.getClientId(),
                onLogout: onLogout,
            )
            .frame(minWidth: 500, minHeight: 400)
        case nil:
            mainAppView
        }
    }

    private var mainAppView: some View {
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

            // Load user profile (provides userId + whitelist check)
            do {
                let profile = try await SpotifyAPI.getCurrentUserProfile(accessToken: token)
                store.setUserProfile(profile)
            } catch SpotifyAPIError.forbidden {
                blockingState = .userNotWhitelisted
                return
            } catch {
                // Profile load failed for other reasons - continue without profile
            }

            // Require Spotify Premium (librespot only works with Premium accounts).
            // The product field was removed from /me, so we probe a premium-only endpoint.
            do {
                _ = try await SpotifyAPI.fetchAvailableDevices(accessToken: token)
            } catch SpotifyAPIError.forbidden {
                blockingState = .premiumRequired
                return
            } catch {
                // Network/other errors - don't block startup, playback will fail later if not premium
            }

            // Load favorites so heart indicators work everywhere
            async let favorites: () = { try? await trackService.loadFavorites(accessToken: token) }()

            // Load startpage data (top artists, top tracks, recently played)
            let timeRange = TopItemsTimeRange(rawValue: topItemsTimeRange) ?? .mediumTerm
            async let topArtists: () = topItemsService.loadTopArtists(accessToken: token, timeRange: timeRange)
            async let topTracks: () = topItemsService.loadTopTracks(accessToken: token, timeRange: timeRange)
            async let recentlyPlayed: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)

            _ = await (favorites, topArtists, topTracks, recentlyPlayed)

            // Set token provider for automatic reconnection
            playbackViewModel.setTokenProvider { await session.validAccessToken() }
            SpotifyPlayer.setTokenProvider(session)

            // Initialize player/Spirc so Spotifly appears as a Connect device
            await playbackViewModel.initializeIfNeeded(accessToken: token)

            // Fetch initial playback state from Web API (Mercury only receives push updates,
            // so we need this to sync with whatever device is currently playing)
            await queueService.fetchInitialPlaybackState(accessToken: token)
        }
        .onReceive(SpotifyPlayer.sessionConnected) {
            // Refresh playback state and devices after session reconnects
            // This handles the case where we transferred playback to another device,
            // the session disconnected, and now we've reconnected
            Task {
                let token = await session.validAccessToken()
                await queueService.fetchInitialPlaybackState(accessToken: token)
                await deviceService.loadDevices(accessToken: token)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            // Disconnect from Spotify Connect before sleep so the device disappears immediately.
            // This is better than pause because a paused device still appears "active" in Spotify
            // but can't respond to commands while the Mac is asleep. Spotify remembers playback
            // position server-side, so clicking play after wake resumes where we left off.
            // disconnect() internally pauses playback and clears the audio buffer synchronously.
            debugLog("LoggedInView", "System will sleep, disconnecting from Spotify")
            SpotifyPlayer.disconnect()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            // After system wake, the TCP connection to Spotify servers is likely dead.
            // Force a reconnection now so playback works reliably when user clicks play.
            debugLog("LoggedInView", "System wake detected, forcing reconnection")
            SpotifyPlayer.forceReconnect()
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
                .help("menu.refresh")
            }
        }
        ToolbarItem(placement: .navigation) {
            if selectedNavigationItem == .queue {
                Button {
                    NotificationCenter.default.post(name: .scrollToCurrentTrack, object: nil)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("queue.scroll_to_current")
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
                Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()

            Button {
                if let externalUrl = album.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("action.share", systemImage: "square.and.arrow.up")
            }
            .disabled(album.externalUrl == nil)

            if let artistId = album.artistId {
                Button {
                    navigationCoordinator.push(.artist(id: artistId))
                } label: {
                    Label("track.menu.go_to_artist", systemImage: "person")
                }
            }

            Divider()

            if isInLibrary {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showAlbumRemoveConfirmation, object: album.id)
                } label: {
                    Label("album.menu.remove_from_library", systemImage: "minus.circle")
                }
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await albumService.saveAlbumToLibrary(albumId: album.id, accessToken: token)
                    }
                } label: {
                    Label("album.menu.add_to_library", systemImage: "plus.circle")
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
                if let externalUrl = artist.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("action.share", systemImage: "square.and.arrow.up")
            }
            .disabled(artist.externalUrl == nil)

            Divider()

            if isFollowing {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showArtistUnfollowConfirmation, object: artist.id)
                } label: {
                    Label("artist.menu.unfollow", systemImage: "person.badge.minus")
                }
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await artistService.followArtist(artistId: artist.id, accessToken: token)
                    }
                } label: {
                    Label("artist.menu.follow", systemImage: "person.badge.plus")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
    }

    private func playlistContextMenu(playlist: Playlist) -> some View {
        let isOwner = playlist.ownerId == store.userId
        let isInLibrary = store.userPlaylistIds.contains(playlist.id)

        return Menu {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: playlist.uri, accessToken: token)
                }
            } label: {
                Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Divider()

            Button {
                if let externalUrl = playlist.externalUrl {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(externalUrl, forType: .string)
                }
            } label: {
                Label("action.share", systemImage: "square.and.arrow.up")
            }
            .disabled(playlist.externalUrl == nil)

            if isOwner {
                Divider()

                Button {
                    NotificationCenter.default.post(name: .showPlaylistEditDetails, object: playlist.id)
                } label: {
                    Label("playlist.menu.edit_details", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistDeleteConfirmation, object: playlist.id)
                } label: {
                    Label("playlist.menu.delete", systemImage: "trash")
                }
            } else {
                Divider()

                if isInLibrary {
                    Button(role: .destructive) {
                        NotificationCenter.default.post(name: .showPlaylistUnfollowConfirmation, object: playlist.id)
                    } label: {
                        Label("playlist.menu.unfollow", systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        Task {
                            let token = await session.validAccessToken()
                            try? await playlistService.followPlaylist(playlistId: playlist.id, accessToken: token)
                        }
                    } label: {
                        Label("playlist.menu.follow", systemImage: "plus.circle")
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

    private func sidebarView() -> some View {
        SidebarView(
            selection: $selectedNavigationItem,
            onLogout: {
                playbackViewModel.stop()
                onLogout()
            },
            hasSearchResults: store.searchResults != nil,
            userProfile: store.userProfile,
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task(id: geometry.size.width) {
                        // Only log and update if width actually changed (not just view recreation)
                        guard sidebarWidth != geometry.size.width else { return }
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

                        case .profile:
                            if let profile = store.userProfile {
                                UserProfileView(userProfile: profile, onLogout: {
                                    playbackViewModel.stop()
                                    onLogout()
                                })
                            }

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
