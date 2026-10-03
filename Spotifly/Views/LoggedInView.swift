//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct LoggedInView: View {
    /// The store and services, which outlive this window; see `LoggedInSession`.
    let session: LoggedInSession
    let onLogout: () -> Void

    @Environment(WindowState.self) private var windowState
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlayerModel.self) private var player

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// Where this window is, which goes with it.
    @State private var navigationCoordinator: NavigationCoordinator

    init(session: LoggedInSession, onLogout: @escaping () -> Void) {
        self.session = session
        self.onLogout = onLogout
        _navigationCoordinator = State(initialValue: NavigationCoordinator(store: session.store))
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
        .environment(session: session)
        .environment(navigationCoordinator)
        // Scene values, which the menu sees whenever the window is key, whatever has focus
        // inside it. The Navigate menu's ⌘1–⌘4, ⌘[ and ⌘] are the only registration of those
        // shortcuts.
        .focusedSceneValue(\.navigationCoordinator, navigationCoordinator)
        .focusedSceneValue(\.homeService, session.homeService)
        .onChange(of: session.store.searchCacheEvictionRevision) {
            navigationCoordinator.invalidateUnviewableRoutes()
        }
        // A failed search's page goes with its failure, from the history too.
        .onChange(of: session.store.failedSearch?.query) {
            navigationCoordinator.invalidateUnviewableRoutes()
        }
        .onChange(of: session.store.deletedEntitySelections) {
            navigationCoordinator.invalidateUnviewableRoutes()
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
                authViewModel.startStreamingAuthorization(expectedAccountId: session.store.userId)
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
            Button("auth.logout", action: onLogout)
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("playback.needs_premium_message")
        }
        // A grant started in here, from Speakers or the play alert, that did not take:
        // refused for another account, or failed. It waits for OK, since the grant finishes in
        // the browser, where a passing message in the bar would be missed.
        .alert(
            "auth.enable_playback_failed_title",
            isPresented: Binding(
                get: { authViewModel.errorMessage != nil },
                set: {
                    if !$0 {
                        authViewModel.errorMessage = nil
                    }
                },
            ),
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(authViewModel.errorMessage ?? "")
        }
    }

    /// The main content router with its content toolbar attached directly. Search is
    /// attached to the NavigationSplitView (see `body`), not here.
    private var contentRouter: some View {
        LoggedInContentRouterView(onLogout: onLogout)
            .toolbar {
                LoggedInContentToolbar(refreshAction: refreshAction(for: navigationCoordinator.selectedNavigationItem))
            }
    }

    private func sidebarView() -> some View {
        SidebarView(
            selection: $navigationCoordinator.selectedNavigationItem,
            // Or a failed search's page, while it shows: the selection is there.
            hasSearchResults: navigationCoordinator.reopenableSearchQuery != nil
                || navigationCoordinator.displayedSearchQuery != nil,
            userProfile: session.store.userProfile,
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

    private func performSearch() {
        let query = searchText
        Task {
            debugLog("Search", "Starting search for: \(query)")
            await session.searchService.search(query: query)
            debugLog("Search", "After search - results: \(session.store.searchResults(for: query) != nil), error: \(session.store.failedSearch?.failure.message ?? "nil")")
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
        session.searchService.clearFailure()

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
                try? await session.playlistService.loadUserPlaylists(forceRefresh: true)
            }

        case .albums:
            {
                try? await session.albumService.loadUserAlbums(forceRefresh: true)
            }

        case .artists:
            {
                try? await session.artistService.loadUserArtists(forceRefresh: true)
            }

        case .favorites:
            {
                try? await session.trackService.loadFavorites(forceRefresh: true)
            }

        case .startpage, .searchResults, .queue, .speakers, .profile, nil:
            nil
        }
    }
}
