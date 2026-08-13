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

    @Environment(WindowState.self) private var windowState
    @Environment(AuthViewModel.self) private var authViewModel

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

    /// Persisted because they store in-flight load tasks for dedup and
    /// cancellation-resilience across view recreation.
    @State private var trackService: TrackService
    @State private var homeService: HomeService

    /// Services whose state lives entirely in AppStore.
    private var searchService: SearchService {
        SearchService(store: store)
    }

    init(authResult: SpotifyAuthResult, onLogout: @escaping () -> Void) {
        self.authResult = authResult
        self.onLogout = onLogout

        let store = AppStore()
        let session = SpotifySession(authResult: authResult)
        // Captures the session, not a token, so every call gets a fresh one.
        let tokenProvider: () async -> String = { await session.validAccessToken() }

        _store = State(initialValue: store)
        _session = State(initialValue: session)
        _playlistService = State(initialValue: PlaylistService(store: store, tokenProvider: tokenProvider))
        _albumService = State(initialValue: AlbumService(store: store))
        _artistService = State(initialValue: ArtistService(store: store))
        let trackService = TrackService(store: store)
        _queueService = State(initialValue: QueueService(store: store, trackService: trackService))
        _connectionService = State(initialValue: ConnectionService(store: store))
        _deviceService = State(initialValue: DeviceService(store: store))
        _navigationCoordinator = State(initialValue: NavigationCoordinator(store: store))
        _trackService = State(initialValue: trackService)
        _homeService = State(initialValue: HomeService(store: store))
    }

    @State private var searchText = ""

    enum BlockingState {
        case premiumRequired
        case userNotWhitelisted
    }

    @State private var blockingState: BlockingState?

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Preferred sidebar column width. The 2-column and 3-column layouts use two
    /// distinct `NavigationSplitView` instances, so a width dragged in one is lost
    /// when switching to a section that swaps to the other. Driving the column's
    /// ideal width from this persisted value keeps the dragged width across the
    /// swap (and across launches).
    @AppStorage("sidebarColumnWidth") private var persistedSidebarWidth: Double = 250
    private static let sidebarMinWidth: CGFloat = 180
    private static let sidebarMaxWidth: CGFloat = 400

    private var navigationSelectionBinding: Binding<NavigationItem?> {
        Binding(
            get: { navigationCoordinator.selectedNavigationItem },
            set: { navigationCoordinator.selectNavigationItem($0) },
        )
    }

    var body: some View {
        content
            // When the refresh token is rejected (revoked, or expired after six
            // months per Spotify's July 2026 policy) the session invalidates
            // itself; tear down and return the user to the sign-in flow.
            .onChange(of: session.isInvalidated) { _, invalidated in
                if invalidated {
                    onLogout()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
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
        Group {
            if windowState.isMiniPlayerMode {
                NowPlayingBarView(
                    playbackViewModel: playbackViewModel,
                    windowState: windowState,
                )
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } detail: {
                    contentRegion
                }
                .navigationSplitViewStyle(.automatic)
                // Always-visible search field, attached to the NavigationSplitView
                // itself (as in the original) — attaching it to an inner view inside
                // the detail column does not surface the field in the window toolbar.
                .searchable(text: $searchText)
                .onSubmit(of: .search) { performSearch() }
                .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
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
        }
        .background(windowState.isMiniPlayerMode ? Color(NSColor.windowBackgroundColor) : Color.clear)
        .searchShortcuts()
        .environment(session)
        .environment(connectionService)
        .environment(deviceService)
        .environment(queueService)
        .environment(homeService)
        .environment(searchService)
        .environment(navigationCoordinator)
        .environment(store)
        .environment(trackService)
        .environment(playlistService)
        .environment(albumService)
        .environment(artistService)
        .focusedValue(\.navigationSelection, navigationSelectionBinding)
        .focusedValue(\.session, session)
        .focusedValue(\.homeService, homeService)
        .loggedInLifecycle(
            session: session,
            store: store,
            playbackViewModel: playbackViewModel,
            queueService: queueService,
            deviceService: deviceService,
            connectionService: connectionService,
            homeService: homeService,
            blockingState: $blockingState,
        )
        .onChange(of: store.searchCacheEvictionRevision) {
            navigationCoordinator.invalidateUnviewableRoutes()
        }
        .onChange(of: store.deletedEntitySelections) {
            navigationCoordinator.invalidateUnviewableRoutes()
        }
        .onChange(of: navigationCoordinator.selectedNavigationItem) { _, newValue in
            guard newValue == .favorites else { return }
            Task {
                await ensureFavoritesLoadedForSelection()
            }
        }
    }

    /// The content region — the detail column of the single, stable two-column
    /// NavigationSplitView. The 2- vs 3-column variation happens *here* (a single
    /// section view, or a list + detail HSplitView), so the sidebar column is never
    /// recreated and keeps its width across every section switch. The now-playing bar
    /// is overlaid here too, so it centers over this region (column 2, or columns
    /// 2+3) the way Apple Music does — no sidebar-width math.
    private var contentRegion: some View {
        Group {
            if navigationCoordinator.needsThreeColumnLayout {
                HSplitView {
                    contentRouter
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 560)

                    LoggedInDetailRouterView(playbackViewModel: playbackViewModel)
                        .frame(maxWidth: .infinity)
                        .toolbar {
                            LoggedInDetailToolbar(playbackViewModel: playbackViewModel)
                        }
                }
            } else {
                contentRouter
            }
        }
        .overlay(alignment: .bottom) {
            NowPlayingBarView(
                playbackViewModel: playbackViewModel,
                windowState: windowState,
            )
        }
        // Raised only when a play request had nowhere to go: no local player and no active
        // remote device. With a device active, playback goes there and nothing is asked.
        .alert(
            "playback.needs_authorization_title",
            isPresented: Bindable(playbackViewModel).needsStreamingAuthorization,
        ) {
            Button("playback.needs_authorization_authorize") {
                // Through the view model, so the grant this starts can be cancelled from
                // Speakers — the alert is gone by the time the browser answers.
                authViewModel.startStreamingAuthorization(expectedAccountId: store.userId)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("playback.needs_authorization_message")
        }
    }

    /// The main content router with its content toolbar attached directly. Search is
    /// attached to the NavigationSplitView (see mainAppView), not here.
    private var contentRouter: some View {
        LoggedInContentRouterView(
            playbackViewModel: playbackViewModel,
            onLogout: handleLogout,
        )
        .toolbar {
            LoggedInContentToolbar(refreshAction: refreshCurrentSection)
        }
    }

    private func sidebarView() -> some View {
        SidebarView(
            selection: navigationSelectionBinding,
            onLogout: handleLogout,
            hasSearchResults: store.lastDisplayedSearchQuery.flatMap(store.searchResults(for:)) != nil,
            userProfile: store.userProfile,
        )
        .navigationSplitViewColumnWidth(
            min: Self.sidebarMinWidth,
            ideal: CGFloat(persistedSidebarWidth),
            max: Self.sidebarMaxWidth,
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { newWidth in
            // Persist the dragged width for launch restore, ignoring the ~0 width
            // reported while the sidebar is collapsed.
            guard newWidth >= Self.sidebarMinWidth, Double(newWidth) != persistedSidebarWidth else { return }
            persistedSidebarWidth = Double(newWidth)
        }
    }

    private func handleLogout() {
        playbackViewModel.stop()
        onLogout()
    }

    private func performSearch() {
        let query = searchText
        Task {
            debugLog("Search", "Starting search for: \(query)")
            // No Web API token: search runs on the keymaster grant now, through the partner
            // API, which is the first call site to move off api.spotify.com.
            await searchService.search(query: query)
            let hasResults = store.searchResults(for: query) != nil
            debugLog("Search", "After search - results: \(hasResults), error: \(store.searchErrorMessage ?? "nil")")
            // The field can be cleared while the request is in flight, which already left
            // the results view; do not navigate back into it behind the user.
            if hasResults, !searchText.isEmpty {
                navigationCoordinator.navigateToSearchResults(query: query)
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        guard newValue.isEmpty else { return }
        store.clearSearchError()

        if navigationCoordinator.selectedNavigationItem == .searchResults {
            navigationCoordinator.selectNavigationItem(.startpage)
        }
    }

    private func refreshCurrentSection() async {
        switch navigationCoordinator.selectedNavigationItem {
        case .playlists:
            let previousSelection = navigationCoordinator.selectedPlaylistId
            store.playlistsPagination.reset()
            store.setUserPlaylistIds([])
            try? await playlistService.loadUserPlaylists(forceRefresh: true)
            navigationCoordinator.restorePlaylistSelection(
                previous: previousSelection,
                available: store.userPlaylistIds,
            )

        case .albums:
            let previousSelection = navigationCoordinator.selectedAlbumId
            store.albumsPagination.reset()
            store.setUserAlbumIds([])
            try? await albumService.loadUserAlbums(forceRefresh: true)
            navigationCoordinator.restoreAlbumSelection(
                previous: previousSelection,
                available: store.userAlbumIds,
            )

        case .artists:
            let previousSelection = navigationCoordinator.selectedArtistId
            store.artistsPagination.reset()
            store.setUserArtistIds([])
            try? await artistService.loadUserArtists(forceRefresh: true)
            navigationCoordinator.restoreArtistSelection(
                previous: previousSelection,
                available: store.userArtistIds,
            )

        case .favorites:
            store.favoritesPagination.reset()
            store.setSavedTrackIds([])
            try? await trackService.loadFavorites(forceRefresh: true)

        case .speakers:
            // Nothing to refresh: the device list is pushed from the cluster.
            break

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

        try? await trackService.loadFavorites(forceRefresh: needsRecoveryRefresh)
    }
}
