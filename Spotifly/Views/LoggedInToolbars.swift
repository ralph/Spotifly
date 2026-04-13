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
    @Bindable var playbackViewModel: PlaybackViewModel

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
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(AlbumService.self) private var albumService
    @Environment(ArtistService.self) private var artistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @Bindable var playbackViewModel: PlaybackViewModel

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

            ShareToolbarButton(externalUrl: album.externalUrl)

            if let artistId = album.artistId {
                Button {
                    navigationCoordinator.navigateToArtistSection(artistId: artistId)
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
            ShareToolbarButton(externalUrl: artist.externalUrl)

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

            ShareToolbarButton(externalUrl: playlist.externalUrl)

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
            } else if isInLibrary {
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

private struct ShareToolbarButton: View {
    let externalUrl: String?

    @State private var showLinkCopied = false
    @State private var linkCopiedDismissTask: Task<Void, Never>?

    var body: some View {
        Button {
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
        .onDisappear {
            linkCopiedDismissTask?.cancel()
            linkCopiedDismissTask = nil
        }
    }
}
