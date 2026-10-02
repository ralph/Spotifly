//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct LoggedInView: View {
    let onLogout: () -> Void

    @Environment(WindowState.self) private var windowState
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerModel.self) private var player

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// Normalized state store.
    @State private var store: AppStore

    // Services that need Task deduplication or subscription persistence.
    @State private var playlistService: PlaylistService
    @State private var profileService: ProfileService
    @State private var albumService: AlbumService
    @State private var artistService: ArtistService
    @State private var queueService: QueueService
    @State private var deviceService: DeviceService
    @State private var navigationCoordinator: NavigationCoordinator

    /// Persisted because they store in-flight load tasks for dedup and
    /// cancellation-resilience across view recreation.
    @State private var trackService: TrackService
    @State private var homeService: HomeService
    /// Holds no state of its own, but kept like the others, so the environment hands the same
    /// instance to every view rather than a new one per evaluation of the body.
    @State private var searchService: SearchService

    init(onLogout: @escaping () -> Void) {
        self.onLogout = onLogout

        let store = AppStore()

        _store = State(initialValue: store)
        let profileService = ProfileService(store: store)
        _profileService = State(initialValue: profileService)
        _playlistService = State(initialValue: PlaylistService(store: store, profileService: profileService))
        _albumService = State(initialValue: AlbumService(store: store))
        _artistService = State(initialValue: ArtistService(store: store))
        let trackService = TrackService(store: store)
        _queueService = State(initialValue: QueueService(store: store, trackService: trackService))
        _deviceService = State(initialValue: DeviceService())
        _navigationCoordinator = State(initialValue: NavigationCoordinator(store: store))
        _trackService = State(initialValue: trackService)
        _homeService = State(initialValue: HomeService(store: store))
        _searchService = State(initialValue: SearchService(store: store))
    }

    @State private var searchText = ""

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
        Bindable(navigationCoordinator).selectedNavigationItem
    }

    var body: some View {
        Group {
            if windowState.isMiniPlayerMode {
                NowPlayingBarView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } detail: {
                    contentRegion
                }
                .navigationSplitViewStyle(.automatic)
                // Always-visible search field, attached to the NavigationSplitView
                // itself — attaching it to an inner view inside the detail column
                // does not surface the field in the window toolbar.
                .searchable(text: $searchText)
                .onSubmit(of: .search) { performSearch() }
                .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
                .onChange(of: player.activeDeviceId) { _, newId in
                    if newId == nil || newId == player.ownDeviceId {
                        playbackViewModel.becameLocalActiveDevice()
                    } else {
                        playbackViewModel.becameRemoteActiveDevice(volumePercent: player.activeDevice?.volumePercent)
                    }
                }
                .onChange(of: player.activeDevice?.volumePercent) { _, newPercent in
                    guard let newPercent, player.activeDeviceId != player.ownDeviceId else { return }
                    playbackViewModel.remoteDeviceVolumeUpdated(newPercent)
                }
            }
        }
        .background(windowState.isMiniPlayerMode ? Color(NSColor.windowBackgroundColor) : Color.clear)
        // Inside the environment below, so the modifier reads the services from it.
        .modifier(LoggedInLifecycleModifier())
        .environment(deviceService)
        .environment(queueService)
        .environment(homeService)
        .environment(searchService)
        .environment(navigationCoordinator)
        .environment(store)
        .environment(trackService)
        .environment(playlistService)
        .environment(profileService)
        .environment(albumService)
        .environment(artistService)
        // Scene values, which the menu sees whenever the window is key, whatever has focus
        // inside it. The Navigate menu's ⌘1–⌘4 are the only registration of those shortcuts.
        .focusedSceneValue(\.navigationSelection, navigationSelectionBinding)
        .focusedSceneValue(\.homeService, homeService)
        .onChange(of: store.searchCacheEvictionRevision) {
            navigationCoordinator.invalidateUnviewableRoutes()
        }
        // A failed search's page goes with its failure, from the history too.
        .onChange(of: store.failedSearch?.query) {
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
                        .frame(minWidth: 280, idealWidth: 380, maxWidth: 560, maxHeight: .infinity)

                    LoggedInDetailRouterView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .toolbar {
                            LoggedInDetailToolbar()
                        }
                }
            } else {
                contentRouter
            }
        }
        // Every pane fills the window's height, whatever it shows. The split view took the
        // height its panes asked for, so a page showing only an error message squeezed the
        // window to its few lines, and the bar below followed it into the window's middle.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Room under every scrolling page, so its end and its scroll bar stay clear of the bar
        // laid over it. It reaches the outermost scroll view of each pane, not the shelves inside,
        // and no `List`, which on macOS takes no content margins: Speakers leaves its own room.
        .contentMargins(.bottom, NowPlayingBarView.contentClearance)
        .overlay(alignment: .bottom) {
            NowPlayingBarView()
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
        // Raised by the first play this Mac cannot start because the account is not Premium.
        // Everything else still works, so this is a notice rather than a screen of its own.
        .alert(
            "playback.needs_premium_title",
            isPresented: Bindable(playbackViewModel).showsPremiumNotice,
        ) {
            Button("auth.logout", action: handleLogout)
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("playback.needs_premium_message")
        }
    }

    /// The main content router with its content toolbar attached directly. Search is
    /// attached to the NavigationSplitView (see `body`), not here.
    private var contentRouter: some View {
        LoggedInContentRouterView(onLogout: handleLogout)
            .toolbar {
                LoggedInContentToolbar(refreshAction: refreshAction(for: navigationCoordinator.selectedNavigationItem))
            }
    }

    private func sidebarView() -> some View {
        SidebarView(
            selection: navigationSelectionBinding,
            // Or a failed search's page, while it shows: the selection is there.
            hasSearchResults: store.lastDisplayedSearchQuery.flatMap(store.searchResults(for:)) != nil
                || navigationCoordinator.displayedSearchQuery != nil,
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
            await searchService.search(query: query)
            debugLog("Search", "After search - results: \(store.searchResults(for: query) != nil), error: \(store.failedSearch?.failure.message ?? "nil")")
            // The page opens for a failure too, to say so. The field can be cleared while the
            // request is in flight, which already left the results view; do not navigate back
            // into it behind the user.
            if !searchText.isEmpty {
                navigationCoordinator.navigateToSearchResults(query: query)
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        guard newValue.isEmpty else { return }
        store.clearSearchFailure()

        if navigationCoordinator.selectedNavigationItem == .searchResults {
            navigationCoordinator.selectNavigationItem(.startpage)
        }
    }

    /// What the toolbar's refresh button does in a section, or nil where there is nothing to
    /// fetch again, and so no button: the queue and Speakers are pushed by the player and the
    /// cluster. One switch for both, so a section cannot show a button that does nothing.
    ///
    /// The same load as pull-to-refresh and Try again. The service resets the paging, and the
    /// first page replaces the list, so the old one stays on screen until the answer arrives.
    /// The selection stays: one past the first page, or opened from elsewhere, is shown as the
    /// section's ephemeral entry, as after any other load.
    private func refreshAction(for section: NavigationItem?) -> (@MainActor @Sendable () async -> Void)? {
        switch section {
        case .playlists:
            {
                try? await playlistService.loadUserPlaylists(forceRefresh: true)
            }

        case .albums:
            {
                try? await albumService.loadUserAlbums(forceRefresh: true)
            }

        case .artists:
            {
                try? await artistService.loadUserArtists(forceRefresh: true)
            }

        case .favorites:
            {
                try? await trackService.loadFavorites(forceRefresh: true)
            }

        case .startpage, .searchResults, .queue, .speakers, .profile, nil:
            nil
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
