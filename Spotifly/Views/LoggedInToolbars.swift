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

    let refreshAction: @MainActor @Sendable () async -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            NavigationHistoryToolbarControl()
        }
        ToolbarItem(placement: .navigation) {
            if navigationCoordinator.canRefreshCurrentSection {
                Button {
                    Task {
                        await refreshAction()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("menu.refresh")
            }
        }
        ToolbarItem(placement: .navigation) {
            if navigationCoordinator.selectedNavigationItem == .queue {
                Button {
                    NotificationCenter.default.post(name: .scrollToCurrentTrack, object: nil)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("queue.scroll_to_current")
            }
        }
    }
}

struct LoggedInDetailToolbar: ToolbarContent {
    let playbackViewModel: PlaybackViewModel

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            LoggedInContextToolbarActions(playbackViewModel: playbackViewModel)
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
            .help(navigationCoordinator.backNavigationTitle.map { String(localized: "nav.back_to \($0)") } ?? String(localized: "nav.back"))
            .disabled(!navigationCoordinator.canNavigateBackward)

            Button {
                navigationCoordinator.navigateForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(navigationCoordinator.forwardNavigationTitle.map { String(localized: "nav.forward_to \($0)") } ?? String(localized: "nav.forward"))
            .disabled(!navigationCoordinator.canNavigateForward)
        }
        .controlGroupStyle(.navigation)
    }
}

private struct LoggedInContextToolbarActions: View {
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(AlbumService.self) private var albumService
    @Environment(ArtistService.self) private var artistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    let playbackViewModel: PlaybackViewModel

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
            if let playlistId = navigationCoordinator.selectedPlaylistId,
               let playlist = store.playlists[playlistId]
            {
                playlistToolbarActions(playlist: playlist)
            }
        default:
            EmptyView()
        }
    }

    private func albumToolbarActions(album: Album) -> some View {
        HStack(spacing: 8) {
            ToolbarActionButton(
                title: "track.menu.play_next",
                systemImage: "text.line.first.and.arrowtriangle.forward",
            ) {
                Task {
                    await playbackViewModel.addToQueue(uri: album.uri)
                }
            }

            ShareToolbarButton(externalUrl: album.externalUrl)

            if let artistId = album.artistId {
                ToolbarActionButton(title: "track.menu.go_to_artist", systemImage: "person") {
                    navigationCoordinator.navigateToArtistSection(artistId: artistId)
                }
            }

            if store.userAlbumIds.contains(album.id) {
                ToolbarActionButton(
                    title: "album.menu.remove_from_library",
                    systemImage: "minus.circle",
                    role: .destructive,
                ) {
                    NotificationCenter.default.post(name: .showAlbumRemoveConfirmation, object: album.id)
                }
            } else {
                ToolbarActionButton(title: "album.menu.add_to_library", systemImage: "plus.circle") {
                    Task {
                        try? await albumService.saveAlbumToLibrary(albumId: album.id)
                    }
                }
            }
        }
    }

    private func artistToolbarActions(artist: Artist) -> some View {
        HStack(spacing: 8) {
            ShareToolbarButton(externalUrl: artist.externalUrl)

            if store.userArtistIds.contains(artist.id) {
                ToolbarActionButton(
                    title: "artist.menu.unfollow",
                    systemImage: "person.badge.minus",
                    role: .destructive,
                ) {
                    NotificationCenter.default.post(name: .showArtistUnfollowConfirmation, object: artist.id)
                }
            } else {
                ToolbarActionButton(title: "artist.menu.follow", systemImage: "person.badge.plus") {
                    Task {
                        try? await artistService.followArtist(artistId: artist.id)
                    }
                }
            }
        }
    }

    private func playlistToolbarActions(playlist: Playlist) -> some View {
        HStack(spacing: 8) {
            ToolbarActionButton(
                title: "track.menu.play_next",
                systemImage: "text.line.first.and.arrowtriangle.forward",
            ) {
                Task {
                    await playbackViewModel.addToQueue(uri: playlist.uri)
                }
            }

            ShareToolbarButton(externalUrl: playlist.externalUrl)

            if playlist.ownerId == store.userId {
                ToolbarActionButton(title: "playlist.menu.edit_details", systemImage: "pencil") {
                    NotificationCenter.default.post(name: .showPlaylistEditDetails, object: playlist.id)
                }

                ToolbarActionButton(title: "playlist.menu.delete", systemImage: "trash", role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistDeleteConfirmation, object: playlist.id)
                }
            } else if store.userPlaylistIds.contains(playlist.id) {
                ToolbarActionButton(title: "playlist.menu.unfollow", systemImage: "minus.circle", role: .destructive) {
                    NotificationCenter.default.post(name: .showPlaylistUnfollowConfirmation, object: playlist.id)
                }
            } else {
                ToolbarActionButton(title: "playlist.menu.follow", systemImage: "plus.circle") {
                    Task {
                        try? await playlistService.followPlaylist(playlistId: playlist.id)
                    }
                }
            }
        }
    }
}

/// The shape every action in the context toolbar has: an icon-only button whose tooltip
/// repeats its own label.
private struct ToolbarActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .help(title)
    }
}

private struct ShareToolbarButton: View {
    let externalUrl: String?

    @State private var showLinkCopied = false
    @State private var linkCopiedDismissTask: Task<Void, Never>?

    var body: some View {
        ToolbarActionButton(title: "action.share", systemImage: "square.and.arrow.up") {
            guard let externalUrl else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(externalUrl, forType: .string)

            showLinkCopied = true
            linkCopiedDismissTask?.cancel()
            linkCopiedDismissTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                showLinkCopied = false
            }
        }
        .disabled(externalUrl == nil)
        .popover(isPresented: $showLinkCopied, arrowEdge: .bottom) {
            Text("action.link_copied")
                .font(.callout)
                .padding(8)
        }
        .onDisappear {
            linkCopiedDismissTask?.cancel()
            linkCopiedDismissTask = nil
        }
    }
}
