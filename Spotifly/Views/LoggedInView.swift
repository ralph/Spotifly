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

    @EnvironmentObject var windowState: WindowState

    @State private var session: SpotifySession
    private let playbackViewModel = PlaybackViewModel.shared

    /// Normalized state store.
    @State private var store: AppStore

    // Services that need Task deduplication or subscription persistence.
    @State private var playlistService: PlaylistService
    @State private var albumService: AlbumService
    @State private var artistService: ArtistService
    @State private var queueService: QueueService
    @State private var connectionService: ConnectionService
    @State private var deviceService: DeviceService
    @State private var navigationCoordinator: NavigationCoordinator

    /// Services whose state lives entirely in AppStore.
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

    init(authResult: SpotifyAuthResult, onLogout: @escaping () -> Void) {
        self.authResult = authResult
        self.onLogout = onLogout

        let store = AppStore()
        let session = SpotifySession(authResult: authResult)

        _store = State(initialValue: store)
        _session = State(initialValue: session)
        _playlistService = State(initialValue: PlaylistService(store: store))
        _albumService = State(initialValue: AlbumService(store: store))
        _artistService = State(initialValue: ArtistService(store: store))
        _queueService = State(initialValue: QueueService(store: store, tokenProvider: {
            await session.validAccessToken()
        }))
        _connectionService = State(initialValue: ConnectionService(store: store))
        _deviceService = State(initialValue: DeviceService(store: store))
        _navigationCoordinator = State(initialValue: NavigationCoordinator(store: store))

        playbackViewModel.setStore(store)
    }

    private let reconnectWatchdogTimeoutSeconds: Double = 120

    @AppStorage("topItemsTimeRange") private var topItemsTimeRange: String = TopItemsTimeRange.mediumTerm.rawValue

    @State private var searchText = ""
    @State private var searchFieldFocused = false

    enum BlockingState {
        case premiumRequired
        case userNotWhitelisted
    }

    @State private var blockingState: BlockingState?

    @State private var sidebarWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var navigationSelectionBinding: Binding<NavigationItem?> {
        Binding(
            get: { navigationCoordinator.selectedNavigationItem },
            set: { navigationCoordinator.selectNavigationItem($0) },
        )
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

            NowPlayingBarView(
                playbackViewModel: playbackViewModel,
                windowState: windowState,
            )
            .padding(.leading, windowState.isMiniPlayerMode ? 0 : nowPlayingLeadingPadding)
        }
        .background(windowState.isMiniPlayerMode ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .searchShortcuts(searchFieldFocused: $searchFieldFocused)
        .environment(session)
        .environment(connectionService)
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
        .focusedValue(\.navigationSelection, navigationSelectionBinding)
        .focusedValue(\.searchFieldFocused, $searchFieldFocused)
        .focusedValue(\.session, session)
        .focusedValue(\.recentlyPlayedService, recentlyPlayedService)
        .loggedInLifecycle(
            session: session,
            store: store,
            topItemsTimeRange: topItemsTimeRange,
            reconnectWatchdogTimeoutSeconds: reconnectWatchdogTimeoutSeconds,
            playbackViewModel: playbackViewModel,
            queueService: queueService,
            deviceService: deviceService,
            recentlyPlayedService: recentlyPlayedService,
            topItemsService: topItemsService,
            blockingState: $blockingState,
        )
        .onChange(of: navigationCoordinator.pendingSectionNavigation) { _, newValue in
            guard let request = newValue else { return }
            navigationCoordinator.applySectionNavigationRequest(request)
            navigationCoordinator.pendingSectionNavigation = nil
        }
        .onChange(of: navigationCoordinator.currentNavigationSnapshot) { oldValue, newValue in
            navigationCoordinator.recordNavigationChange(from: oldValue, to: newValue)
        }
        .onChange(of: navigationCoordinator.selectedNavigationItem) { _, newValue in
            guard newValue == .favorites else { return }
            Task {
                await ensureFavoritesLoadedForSelection()
            }
        }
    }

    private var nowPlayingLeadingPadding: CGFloat {
        columnVisibility == .detailOnly ? 0 : sidebarWidth + 8
    }

    private var mainLayoutView: some View {
        Group {
            if navigationCoordinator.needsThreeColumnLayout {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } content: {
                    LoggedInContentRouterView(
                        playbackViewModel: playbackViewModel,
                        onLogout: handleLogout,
                    )
                    .navigationSplitViewColumnWidth(min: 300, ideal: 450, max: 600)
                    .toolbar {
                        LoggedInContentToolbar(refreshAction: refreshCurrentSection)
                    }
                } detail: {
                    LoggedInDetailRouterView(playbackViewModel: playbackViewModel)
                        .toolbar {
                            LoggedInDetailToolbar(playbackViewModel: playbackViewModel)
                        }
                        .searchable(text: $searchText, isPresented: $searchFieldFocused)
                        .onSubmit(of: .search) { performSearch() }
                        .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } detail: {
                    LoggedInContentRouterView(
                        playbackViewModel: playbackViewModel,
                        onLogout: handleLogout,
                    )
                    .toolbar {
                        LoggedInContentToolbar(refreshAction: refreshCurrentSection)
                    }
                    .searchable(text: $searchText, isPresented: $searchFieldFocused)
                    .onSubmit(of: .search) { performSearch() }
                    .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
                }
            }
        }
        .navigationSplitViewStyle(.automatic)
        .onChange(of: store.activeDeviceId) { _, newId in
            if newId == nil || newId == store.ownDeviceId {
                playbackViewModel.becameLocalActiveDevice()
            } else {
                playbackViewModel.becameRemoteActiveDevice(volumePercent: store.activeDevice?.volumePercent)
            }
        }
        .onChange(of: store.activeDevice?.volumePercent) { _, newPercent in
            guard let newPercent, store.activeDeviceId != store.ownDeviceId else { return }
            playbackViewModel.remoteDeviceVolumeUpdated(newPercent)
        }
    }

    private func sidebarView() -> some View {
        SidebarView(
            selection: navigationSelectionBinding,
            onLogout: handleLogout,
            hasSearchResults: store.searchResults != nil,
            userProfile: store.userProfile,
        )
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task(id: geometry.size.width) {
                        guard sidebarWidth != geometry.size.width else { return }
                        debugLog("SidebarWidth", "Updating sidebarWidth to: \(geometry.size.width)")
                        await MainActor.run {
                            sidebarWidth = geometry.size.width
                        }
                    }
            }
        }
    }

    private func handleLogout() {
        playbackViewModel.stop()
        onLogout()
    }

    private func performSearch() {
        Task {
            let token = await session.validAccessToken()
            debugLog("Search", "Starting search for: \(searchText)")
            await searchService.search(accessToken: token, query: searchText)
            debugLog("Search", "After search - results: \(store.searchResults != nil), error: \(store.searchErrorMessage ?? "nil")")
            if store.searchResults != nil {
                navigationCoordinator.selectNavigationItem(.searchResults)
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        guard newValue.isEmpty else { return }

        store.clearSearch()
        navigationCoordinator.pruneSearchHistory()

        if navigationCoordinator.selectedNavigationItem == .searchResults {
            navigationCoordinator.selectNavigationItem(.startpage)
        }
    }

    private func refreshCurrentSection() async {
        let token = await session.validAccessToken()

        switch navigationCoordinator.selectedNavigationItem {
        case .playlists:
            let previousSelection = navigationCoordinator.selectedPlaylistId
            store.playlistsPagination.reset()
            store.setUserPlaylistIds([])
            try? await playlistService.loadUserPlaylists(accessToken: token, forceRefresh: true)
            navigationCoordinator.restorePlaylistSelection(
                previous: previousSelection,
                available: store.userPlaylistIds,
            )

        case .albums:
            let previousSelection = navigationCoordinator.selectedAlbumId
            store.albumsPagination.reset()
            store.setUserAlbumIds([])
            try? await albumService.loadUserAlbums(accessToken: token, forceRefresh: true)
            navigationCoordinator.restoreAlbumSelection(
                previous: previousSelection,
                available: store.userAlbumIds,
            )

        case .artists:
            let previousSelection = navigationCoordinator.selectedArtistId
            store.artistsPagination.reset()
            store.setUserArtistIds([])
            try? await artistService.loadUserArtists(accessToken: token, forceRefresh: true)
            navigationCoordinator.restoreArtistSelection(
                previous: previousSelection,
                available: store.userArtistIds,
            )

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

    private func ensureFavoritesLoadedForSelection() async {
        guard navigationCoordinator.selectedNavigationItem == .favorites else { return }
        guard !store.favoritesPagination.isLoading else { return }

        let needsInitialLoad = !store.favoritesPagination.isLoaded
        let needsRecoveryRefresh = store.favoriteTracks.isEmpty && store.favoritesPagination.total > 0

        guard needsInitialLoad || needsRecoveryRefresh else { return }

        let token = await session.validAccessToken()
        guard navigationCoordinator.selectedNavigationItem == .favorites else { return }

        try? await trackService.loadFavorites(
            accessToken: token,
            forceRefresh: needsRecoveryRefresh,
        )
    }
}
