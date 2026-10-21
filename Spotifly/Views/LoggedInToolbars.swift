//
//  LoggedInToolbars.swift
//  Spotifly
//
//  Toolbar content extracted from LoggedInView.
//

import AppKit
import SwiftUI

struct LoggedInContentToolbar: ToolbarContent {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    /// Nil where the section has nothing to refresh, which shows no button.
    let refreshAction: (@MainActor @Sendable () async -> Void)?

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            NavigationHistoryToolbarControl()
        }
        ToolbarItem(placement: .navigation) {
            if let refreshAction {
                ToolbarActionButton(title: "menu.refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await refreshAction()
                    }
                }
            }
        }
        ToolbarItem(placement: .navigation) {
            if navigationCoordinator.selectedNavigationItem == .queue {
                ToolbarActionButton(title: "queue.scroll_to_current", systemImage: "arrow.down.to.line") {
                    NotificationCenter.default.post(name: .scrollToCurrentTrack, object: nil)
                }
            }
        }
        // The album list's sort, at the leading edge where the handoff has it.
        ToolbarItem(placement: .navigation) {
            if navigationCoordinator.selectedNavigationItem == .albums {
                AlbumSortPicker()
            }
        }
    }
}

private struct AlbumSortPicker: View {
    @Environment(AlbumService.self) private var albumService

    var body: some View {
        Picker("library.sort", selection: Binding(get: { albumService.sort }, set: { sort in
            Task { try? await albumService.setSort(sort) }
        })) {
            ForEach(AlbumSort.allCases, id: \.self) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("library.sort")
    }
}

struct LoggedInDetailToolbar: ToolbarContent {
    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            LoggedInContextToolbarActions()
        }
    }
}

private struct NavigationHistoryToolbarControl: View {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        ControlGroup {
            Button {
                navigationCoordinator.navigateBackward()
            } label: {
                Image(systemName: "chevron.left")
            }
            .named(navigationCoordinator.backNavigationTitle.map { "nav.back_to \($0)" } ?? "nav.back")
            .disabled(!navigationCoordinator.canNavigateBackward)

            Button {
                navigationCoordinator.navigateForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .named(navigationCoordinator.forwardNavigationTitle.map { "nav.forward_to \($0)" } ?? "nav.forward")
            .disabled(!navigationCoordinator.canNavigateForward)
        }
        .controlGroupStyle(.navigation)
    }
}

private struct LoggedInContextToolbarActions: View {
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(ArtistService.self) private var artistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var showNewPlaylist = false

    var body: some View {
        switch navigationCoordinator.selectedNavigationItem {
        case .albums:
            if let albumId = navigationCoordinator.selectedAlbumId,
               let album = store.albums[albumId]
            {
                albumToolbarActions(album: album)
            }
        case .artists:
            if let artistId = navigationCoordinator.selectedArtistId,
               let artist = store.artists[artistId]
            {
                artistToolbarActions(artist: artist)
            }
        case .playlists:
            // New Playlist with or without a playlist selected: an account with none needs it most.
            HStack(spacing: 8) {
                ToolbarActionButton(title: "playlist.new.title", systemImage: "plus") {
                    showNewPlaylist = true
                }

                if let playlistId = navigationCoordinator.selectedPlaylistId,
                   let playlist = store.playlists[playlistId]
                {
                    playlistToolbarActions(playlist: playlist)
                }
            }
            // A new playlist opens as soon as it is made.
            .newPlaylistPrompt(isPresented: $showNewPlaylist, trackId: nil, onAdded: {}) { created in
                navigationCoordinator.selectPlaylist(created.id)
            }
        default:
            EmptyView()
        }
    }

    /// The handoff's album toolbar.
    private func albumToolbarActions(album: Album) -> some View {
        shareAndMoreMenu(uri: album.uri) {
            Menu {
                PlaylistSubmenuContent(store: store, playlistService: playlistService) { playlistId in
                    addTracks(album.trackIds, toPlaylist: playlistId)
                }
            } label: {
                Label("track.menu.add_to_playlist", systemImage: "music.note.list")
            }
            .disabled(album.trackIds.isEmpty)

            Divider()

            if let artistId = album.artistId {
                Button("track.menu.go_to_artist", systemImage: "person") {
                    navigationCoordinator.navigateToArtistSection(artistId: artistId)
                }
            }
        }
    }

    private func addTracks(_ trackIds: [String], toPlaylist playlistId: String) {
        Task {
            do {
                try await playlistService.addTracksToPlaylist(playlistId: playlistId, trackIds: trackIds)
            } catch {
                playbackViewModel.errorMessage = String(localized: "error.add_to_playlist \(error.localizedDescription)")
            }
        }
    }

    /// The handoff's artist toolbar: nothing to queue, as an artist is not a list of tracks.
    private func artistToolbarActions(artist: Artist) -> some View {
        shareAndMoreMenu(uri: artist.uri, canQueue: false) {
            if store.userArtistIds.contains(artist.id) {
                Button("artist.menu.unfollow", systemImage: "person.badge.minus") {
                    NotificationCenter.default.post(name: .showArtistUnfollowConfirmation, object: artist.id)
                }
            } else {
                Button("artist.menu.follow", systemImage: "person.badge.plus") {
                    Task { try? await artistService.followArtist(artistId: artist.id) }
                }
            }
        }
    }

    /// The handoff's playlist toolbar.
    private func playlistToolbarActions(playlist: Playlist) -> some View {
        shareAndMoreMenu(uri: playlist.uri) {
            Divider()

            if playlist.ownerId == store.userId {
                Button("playlist.menu.edit_details", systemImage: "pencil") {
                    NotificationCenter.default.post(name: .showPlaylistEditDetails, object: playlist.id)
                }
                Button("playlist.menu.choose_cover", systemImage: "photo") {
                    NotificationCenter.default.post(name: .showPlaylistCoverPicker, object: playlist.id)
                }
                Button("playlist.menu.remove_cover") {
                    NotificationCenter.default.post(name: .showPlaylistRemoveCoverConfirmation, object: playlist.id)
                }
                Button("playlist.menu.delete", systemImage: "trash", role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistDeleteConfirmation, object: playlist.id)
                }
            } else if store.userPlaylistIds.contains(playlist.id) {
                Button("playlist.menu.unfollow", systemImage: "minus.circle") {
                    NotificationCenter.default.post(name: .showPlaylistUnfollowConfirmation, object: playlist.id)
                }
            } else {
                Button("playlist.menu.follow", systemImage: "plus.circle") {
                    Task { try? await playlistService.followPlaylist(playlistId: playlist.id) }
                }
            }
        }
    }

    /// Share, and a menu of Play, Play Next, what the page adds, and Copy Link.
    private func shareAndMoreMenu(uri: String, canQueue: Bool = true, @ViewBuilder pageItems: () -> some View) -> some View {
        HStack(spacing: 8) {
            shareLink(for: uri)

            Menu {
                Button("action.play", systemImage: "play.fill") {
                    Task { await playbackViewModel.play(uriOrUrl: uri) }
                }
                if canQueue {
                    Button("track.menu.play_next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        Task { await playbackViewModel.addToQueue(uri: uri) }
                    }
                }

                pageItems()

                Divider()

                Button("action.copy_link", systemImage: "link") {
                    copyLink(of: uri)
                }
            } label: {
                Label("action.more", systemImage: "ellipsis")
            }
            .labelStyle(.iconOnly)
            .help("action.more")
        }
    }

    @ViewBuilder
    private func shareLink(for uri: String) -> some View {
        if let link = SpotifyURI.webURL(uri).flatMap(URL.init(string:)) {
            ShareLink(item: link) {
                Label("action.share", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .help("action.share")
        }
    }

    private func copyLink(of uri: String) {
        guard let link = SpotifyURI.webURL(uri) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }
}

/// The shape every action in the context toolbar has: an icon-only button whose tooltip
/// repeats its own label.
private struct ToolbarActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .help(title)
    }
}
