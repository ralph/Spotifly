//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import Combine
import SwiftUI

private struct NavigationSnapshot: Equatable {
    var section: NavigationItem?
    var selectedAlbumId: String?
    var selectedArtistId: String?
    var selectedPlaylistId: String?
    var navigationPath: [NavigationDestination]
    var viewingAlbumId: String?
    var viewingArtistId: String?
    var viewingPlaylistId: String?
}

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

    private let reconnectWatchdogTimeoutSeconds: Double = 120

    @AppStorage("topItemsTimeRange") private var topItemsTimeRange: String = TopItemsTimeRange.mediumTerm.rawValue

    @State private var selectedNavigationItem: NavigationItem? = .startpage
    @State private var searchText = ""
    @State private var searchFieldFocused = false
    @State private var navigationBackStack: [NavigationSnapshot] = []
    @State private var navigationForwardStack: [NavigationSnapshot] = []
    @State private var historyRestoreTarget: NavigationSnapshot?

    // Selection state for library detail views (ID-based)
    @State private var selectedAlbumId: String?
    @State private var selectedArtistId: String?
    @State private var selectedPlaylistId: String?
    @State private var showLinkCopied = false
    @State private var linkCopiedDismissTask: Task<Void, Never>?

    /// Blocking state shown instead of the main app
    enum BlockingState {
        case premiumRequired
        case userNotWhitelisted
    }

    @State private var blockingState: BlockingState?

    // Sidebar width for dynamic now playing bar positioning
    @State private var sidebarWidth: CGFloat = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var reconnectWatchdogTask: Task<Void, Never>?

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

    private var currentNavigationSnapshot: NavigationSnapshot {
        NavigationSnapshot(
            section: selectedNavigationItem,
            selectedAlbumId: selectedAlbumId,
            selectedArtistId: selectedArtistId,
            selectedPlaylistId: selectedPlaylistId,
            navigationPath: navigationCoordinator.navigationPath,
            viewingAlbumId: navigationCoordinator.viewingAlbumId,
            viewingArtistId: navigationCoordinator.viewingArtistId,
            viewingPlaylistId: navigationCoordinator.viewingPlaylistId,
        )
    }

    private var navigationSelectionBinding: Binding<NavigationItem?> {
        Binding(
            get: { selectedNavigationItem },
            set: { newValue in
                selectNavigationItem(newValue)
            },
        )
    }

    private var canNavigateBackward: Bool {
        !navigationBackStack.isEmpty
    }

    private var canNavigateForward: Bool {
        !navigationForwardStack.isEmpty
    }

    private var backNavigationTitle: String? {
        navigationBackStack.last.map(title(for:))
    }

    private var forwardNavigationTitle: String? {
        navigationForwardStack.last.map(title(for:))
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

            // Load startpage data (top artists, top tracks, recently played)
            let timeRange = TopItemsTimeRange(rawValue: topItemsTimeRange) ?? .mediumTerm
            async let topArtists: () = topItemsService.loadTopArtists(accessToken: token, timeRange: timeRange)
            async let topTracks: () = topItemsService.loadTopTracks(accessToken: token, timeRange: timeRange)
            async let recentlyPlayed: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)

            _ = await (topArtists, topTracks, recentlyPlayed)

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
            // Cancel watchdog — session recovered on its own (or via reinit).
            reconnectWatchdogTask?.cancel()
            reconnectWatchdogTask = nil
            // Refresh playback state after session reconnects.
            // After a transfer the Web API returns stale data for a few seconds,
            // so we delay the fetch to let the server catch up.
            // Device active state is now updated via the cluster callback, no HTTP needed here.
            Task {
                let token = await session.validAccessToken()
                await deviceService.waitForTransferSettling()
                await queueService.fetchInitialPlaybackState(accessToken: token)
            }
        }
        .onReceive(SpotifyPlayer.sessionDisconnected) {
            // Cancel any prior watchdog and start a fresh one.
            // If isSessionConnected is still false after the timeout, the Rust loop has stalled
            // (authenticated but Spirc not ready) — force a full reinit.
            reconnectWatchdogTask?.cancel()
            reconnectWatchdogTask = Task {
                // try? is load-bearing: Task.sleep throws CancellationError when cancelled,
                // which would skip the guard below. try? silences it so the guard runs
                // and cleanly returns via !Task.isCancelled.
                try? await Task.sleep(for: .seconds(reconnectWatchdogTimeoutSeconds))
                guard !Task.isCancelled, !SpotifyPlayer.isSessionConnected else { return }
                debugLog("LoggedInView", "Watchdog: still disconnected after \(Int(reconnectWatchdogTimeoutSeconds))s, forcing reinit")
                let token = await session.validAccessToken()
                await playbackViewModel.forceReinitialize(accessToken: token)
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
            // After system wake, the TCP connection to Spotify servers is dead.
            // forceReconnect() (the Rust reconnect loop) can get stuck: it may authenticate
            // successfully but fail to bring Spirc up, leaving the app permanently broken.
            // forceReinitialize does a full Rust teardown + reinit which is reliably clean.
            debugLog("LoggedInView", "System wake detected, forcing full reinit")
            Task {
                let token = await session.validAccessToken()
                await playbackViewModel.forceReinitialize(accessToken: token)
            }
        }
        .onChange(of: navigationCoordinator.pendingSectionNavigation) { _, newValue in
            if let request = newValue {
                applySectionNavigationRequest(request)
                navigationCoordinator.pendingSectionNavigation = nil
            }
        }
        .onChange(of: currentNavigationSnapshot) { oldValue, newValue in
            recordNavigationChange(from: oldValue, to: newValue)
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
                        .toolbar { contentColumnToolbar }
                } detail: {
                    detailView()
                        .toolbar { detailColumnToolbar }
                        .searchable(text: $searchText, isPresented: $searchFieldFocused)
                        .onSubmit(of: .search) { performSearch() }
                        .onChange(of: searchText) { _, newValue in handleSearchTextChange(newValue) }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView()
                } detail: {
                    contentView()
                        .toolbar { contentColumnToolbar }
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

    @ToolbarContentBuilder
    private var contentColumnToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            navigationHistoryToolbar
        }
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
    }

    @ToolbarContentBuilder
    private var detailColumnToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            contextToolbarActions
        }
    }

    private var navigationHistoryToolbar: some View {
        ControlGroup {
            Button {
                navigateBackward()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(backNavigationTitle.map { "Back to \($0)" } ?? "Back")
            .disabled(!canNavigateBackward)

            Button {
                navigateForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(forwardNavigationTitle.map { "Forward to \($0)" } ?? "Forward")
            .disabled(!canNavigateForward)
        }
        .controlGroupStyle(.navigation)
    }

    // MARK: - Context Actions

    @ViewBuilder
    private var contextToolbarActions: some View {
        switch selectedNavigationItem {
        case .albums:
            if let albumId = selectedAlbumId, let album = store.albums[albumId] {
                albumToolbarActions(album: album)
            }
        case .artists:
            if let artistId = selectedArtistId, let artist = store.artists[artistId] {
                artistToolbarActions(artist: artist)
            }
        case .playlists:
            if let playlistId = selectedPlaylistId, let playlist = store.playlists[playlistId] {
                playlistToolbarActions(playlist: playlist)
            }
        default:
            EmptyView()
        }
    }

    private func albumToolbarActions(album: Album) -> some View {
        let isInLibrary = store.userAlbumIds.contains(album.id)

        return HStack(spacing: 8) {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: album.uri, accessToken: token)
                }
            } label: {
                Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .labelStyle(.iconOnly)
            .help("track.menu.play_next")

            shareToolbarButton(externalUrl: album.externalUrl)

            if let artistId = album.artistId {
                Button {
                    navigationCoordinator.navigateToArtistSection(
                        artistId: artistId,
                        from: .albums,
                        selectionId: album.id,
                    )
                } label: {
                    Label("track.menu.go_to_artist", systemImage: "person")
                }
                .labelStyle(.iconOnly)
                .help("track.menu.go_to_artist")
            }

            if isInLibrary {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showAlbumRemoveConfirmation, object: album.id)
                } label: {
                    Label("album.menu.remove_from_library", systemImage: "minus.circle")
                }
                .labelStyle(.iconOnly)
                .help("album.menu.remove_from_library")
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await albumService.saveAlbumToLibrary(albumId: album.id, accessToken: token)
                    }
                } label: {
                    Label("album.menu.add_to_library", systemImage: "plus.circle")
                }
                .labelStyle(.iconOnly)
                .help("album.menu.add_to_library")
            }
        }
    }

    private func artistToolbarActions(artist: Artist) -> some View {
        let isFollowing = store.userArtistIds.contains(artist.id)

        return HStack(spacing: 8) {
            shareToolbarButton(externalUrl: artist.externalUrl)

            if isFollowing {
                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showArtistUnfollowConfirmation, object: artist.id)
                } label: {
                    Label("artist.menu.unfollow", systemImage: "person.badge.minus")
                }
                .labelStyle(.iconOnly)
                .help("artist.menu.unfollow")
            } else {
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        try? await artistService.followArtist(artistId: artist.id, accessToken: token)
                    }
                } label: {
                    Label("artist.menu.follow", systemImage: "person.badge.plus")
                }
                .labelStyle(.iconOnly)
                .help("artist.menu.follow")
            }
        }
    }

    private func playlistToolbarActions(playlist: Playlist) -> some View {
        let isOwner = playlist.ownerId == store.userId
        let isInLibrary = store.userPlaylistIds.contains(playlist.id)

        return HStack(spacing: 8) {
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.addToQueue(uri: playlist.uri, accessToken: token)
                }
            } label: {
                Label("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .labelStyle(.iconOnly)
            .help("track.menu.play_next")

            shareToolbarButton(externalUrl: playlist.externalUrl)

            if isOwner {
                Button {
                    NotificationCenter.default.post(name: .showPlaylistEditDetails, object: playlist.id)
                } label: {
                    Label("playlist.menu.edit_details", systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .help("playlist.menu.edit_details")

                Button(role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistDeleteConfirmation, object: playlist.id)
                } label: {
                    Label("playlist.menu.delete", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("playlist.menu.delete")
            } else {
                if isInLibrary {
                    Button(role: .destructive) {
                        NotificationCenter.default.post(name: .showPlaylistUnfollowConfirmation, object: playlist.id)
                    } label: {
                        Label("playlist.menu.unfollow", systemImage: "minus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("playlist.menu.unfollow")
                } else {
                    Button {
                        Task {
                            let token = await session.validAccessToken()
                            try? await playlistService.followPlaylist(playlistId: playlist.id, accessToken: token)
                        }
                    } label: {
                        Label("playlist.menu.follow", systemImage: "plus.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("playlist.menu.follow")
                }
            }
        }
    }

    private func shareToolbarButton(externalUrl: String?) -> some View {
        Button {
            if let externalUrl {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(externalUrl, forType: .string)
                showLinkCopied = true
                linkCopiedDismissTask?.cancel()
                linkCopiedDismissTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled {
                        showLinkCopied = false
                    }
                }
            }
        } label: {
            Label("action.share", systemImage: "square.and.arrow.up")
        }
        .labelStyle(.iconOnly)
        .help("action.share")
        .disabled(externalUrl == nil)
        .popover(isPresented: $showLinkCopied, arrowEdge: .bottom) {
            Text("action.link_copied")
                .font(.callout)
                .padding(8)
        }
    }

    private func performSearch() {
        Task {
            let token = await session.validAccessToken()
            debugLog("Search", "Starting search for: \(searchText)")
            await searchService.search(accessToken: token, query: searchText)
            debugLog("Search", "After search - results: \(store.searchResults != nil), error: \(store.searchErrorMessage ?? "nil")")
            if store.searchResults != nil {
                selectNavigationItem(.searchResults)
            }
        }
    }

    private func handleSearchTextChange(_ newValue: String) {
        if newValue.isEmpty {
            store.clearSearch()
            pruneNavigationHistory { snapshot in
                snapshot.section == .searchResults
            }
            if selectedNavigationItem == .searchResults {
                selectNavigationItem(.startpage)
            }
        }
    }

    private func handleBackNavigation() {
        navigateBackward()
    }

    private func sidebarView() -> some View {
        SidebarView(
            selection: navigationSelectionBinding,
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

    private func ensureFavoritesLoadedForSelection() async {
        guard selectedNavigationItem == .favorites else { return }
        guard !store.favoritesPagination.isLoading else { return }

        let needsInitialLoad = !store.favoritesPagination.isLoaded
        let needsRecoveryRefresh = store.favoriteTracks.isEmpty && store.favoritesPagination.total > 0

        guard needsInitialLoad || needsRecoveryRefresh else { return }

        let token = await session.validAccessToken()
        guard selectedNavigationItem == .favorites else { return }

        try? await trackService.loadFavorites(
            accessToken: token,
            forceRefresh: needsRecoveryRefresh,
        )
    }

    private func selectNavigationItem(_ newValue: NavigationItem?) {
        let oldValue = selectedNavigationItem
        guard oldValue != newValue else { return }

        navigationCoordinator.clearNavigationStack()

        if oldValue == .albums, newValue != .albums {
            navigationCoordinator.viewingAlbumId = nil
        }
        if oldValue == .artists, newValue != .artists {
            navigationCoordinator.viewingArtistId = nil
        }
        if oldValue == .playlists, newValue != .playlists {
            navigationCoordinator.viewingPlaylistId = nil
        }

        selectedNavigationItem = newValue
        navigationCoordinator.currentSection = newValue ?? .startpage

        if newValue == .favorites {
            Task {
                await ensureFavoritesLoadedForSelection()
            }
        }
    }

    private func applySectionNavigationRequest(_ request: SectionNavigationRequest) {
        navigationCoordinator.viewingAlbumId = request.albumId
        navigationCoordinator.viewingArtistId = request.artistId
        navigationCoordinator.viewingPlaylistId = request.playlistId

        if let albumId = request.albumId {
            selectedAlbumId = albumId
        }
        if let artistId = request.artistId {
            selectedArtistId = artistId
        }
        if let playlistId = request.playlistId {
            selectedPlaylistId = playlistId
        }

        selectNavigationItem(request.section)
    }

    private func navigateBackward() {
        guard let previousSnapshot = navigationBackStack.popLast() else { return }
        navigationForwardStack.append(currentNavigationSnapshot)
        applyNavigationSnapshot(previousSnapshot)
    }

    private func navigateForward() {
        guard let nextSnapshot = navigationForwardStack.popLast() else { return }
        navigationBackStack.append(currentNavigationSnapshot)
        applyNavigationSnapshot(nextSnapshot)
    }

    private func applyNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        historyRestoreTarget = snapshot

        selectedAlbumId = snapshot.selectedAlbumId
        selectedArtistId = snapshot.selectedArtistId
        selectedPlaylistId = snapshot.selectedPlaylistId
        navigationCoordinator.viewingAlbumId = snapshot.viewingAlbumId
        navigationCoordinator.viewingArtistId = snapshot.viewingArtistId
        navigationCoordinator.viewingPlaylistId = snapshot.viewingPlaylistId
        navigationCoordinator.navigationPath = snapshot.navigationPath
        selectedNavigationItem = snapshot.section
        navigationCoordinator.currentSection = snapshot.section ?? .startpage

        if snapshot.section == .favorites {
            Task {
                await ensureFavoritesLoadedForSelection()
            }
        }
    }

    private func recordNavigationChange(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) {
        if let historyRestoreTarget {
            if newValue == historyRestoreTarget {
                self.historyRestoreTarget = nil
            }
            return
        }
        guard shouldRecordNavigationChange(from: oldValue, to: newValue) else { return }

        navigationBackStack.append(oldValue)
        if navigationBackStack.count > 100 {
            navigationBackStack.removeFirst(navigationBackStack.count - 100)
        }
        navigationForwardStack.removeAll()
    }

    private func shouldRecordNavigationChange(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) -> Bool {
        guard oldValue != newValue else { return false }
        if oldValue.section == .searchResults, store.searchResults == nil {
            return false
        }
        return !isImplicitLibraryAutoSelection(from: oldValue, to: newValue)
    }

    private func isImplicitLibraryAutoSelection(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) -> Bool {
        guard oldValue.section == newValue.section,
              oldValue.navigationPath == newValue.navigationPath,
              oldValue.viewingAlbumId == newValue.viewingAlbumId,
              oldValue.viewingArtistId == newValue.viewingArtistId,
              oldValue.viewingPlaylistId == newValue.viewingPlaylistId
        else {
            return false
        }

        switch newValue.section {
        case .albums:
            return oldValue.selectedAlbumId == nil &&
                newValue.selectedAlbumId != nil &&
                oldValue.selectedArtistId == newValue.selectedArtistId &&
                oldValue.selectedPlaylistId == newValue.selectedPlaylistId
        case .artists:
            return oldValue.selectedArtistId == nil &&
                newValue.selectedArtistId != nil &&
                oldValue.selectedAlbumId == newValue.selectedAlbumId &&
                oldValue.selectedPlaylistId == newValue.selectedPlaylistId
        case .playlists:
            return oldValue.selectedPlaylistId == nil &&
                newValue.selectedPlaylistId != nil &&
                oldValue.selectedAlbumId == newValue.selectedAlbumId &&
                oldValue.selectedArtistId == newValue.selectedArtistId
        default:
            return false
        }
    }

    private func pruneNavigationHistory(where shouldRemove: (NavigationSnapshot) -> Bool) {
        navigationBackStack.removeAll(where: shouldRemove)
        navigationForwardStack.removeAll(where: shouldRemove)
    }

    private func title(for snapshot: NavigationSnapshot) -> String {
        if let destination = snapshot.navigationPath.last {
            switch destination {
            case let .artist(id):
                return store.artists[id]?.name ?? NavigationItem.artists.title
            case let .album(id):
                return store.albums[id]?.name ?? NavigationItem.albums.title
            case let .playlist(id):
                return store.playlists[id]?.name ?? NavigationItem.playlists.title
            case .searchTracks:
                return String(localized: "section.tracks")
            }
        }

        switch snapshot.section {
        case .albums:
            if let albumId = snapshot.selectedAlbumId, let album = store.albums[albumId] {
                return album.name
            }
            return NavigationItem.albums.title
        case .artists:
            if let artistId = snapshot.selectedArtistId, let artist = store.artists[artistId] {
                return artist.name
            }
            return NavigationItem.artists.title
        case .playlists:
            if let playlistId = snapshot.selectedPlaylistId, let playlist = store.playlists[playlistId] {
                return playlist.name
            }
            return NavigationItem.playlists.title
        case let section?:
            return section.title
        case nil:
            break
        }

        return String(localized: "app.name")
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
                                backTitle: backNavigationTitle,
                                onBack: handleBackNavigation,
                            )
                            .navigationTitle("nav.playlists")

                        case .albums:
                            AlbumsListView(
                                playbackViewModel: playbackViewModel,
                                selectedAlbumId: $selectedAlbumId,
                                backTitle: backNavigationTitle,
                                onBack: handleBackNavigation,
                            )
                            .navigationTitle("nav.albums")

                        case .artists:
                            ArtistsListView(
                                playbackViewModel: playbackViewModel,
                                selectedArtistId: $selectedArtistId,
                                backTitle: backNavigationTitle,
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
                    .libraryNavigationShortcuts(selection: navigationSelectionBinding)
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

        case let .searchTracks(ids):
            SearchAllTracksView(
                trackIds: ids,
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
                if let playlistId = selectedPlaylistId,
                   let playlist = store.playlists[playlistId]
                {
                    PlaylistDetailView(
                        playlist: playlist,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(playlistId) // Force view recreation when playlist changes
                } else if let playlistId = selectedPlaylistId {
                    // Playlist ID is set but not in store yet - show loading and fetch
                    PlaylistDetailView(
                        playlistId: playlistId,
                        playbackViewModel: playbackViewModel,
                    )
                    .id(playlistId)
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
