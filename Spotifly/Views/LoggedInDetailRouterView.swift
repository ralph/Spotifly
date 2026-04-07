//
//  LoggedInDetailRouterView.swift
//  Spotifly
//
//  Routes the logged-in detail column for three-column library sections.
//

import SwiftUI

struct LoggedInDetailRouterView: View {
    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            switch navigationCoordinator.selectedNavigationItem {
            case .albums:
                albumDetailView

            case .artists:
                artistDetailView

            case .playlists:
                playlistDetailView

            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var albumDetailView: some View {
        if let albumId = navigationCoordinator.selectedAlbumId,
           let album = store.albums[albumId]
        {
            AlbumDetailView(
                album: album,
                playbackViewModel: playbackViewModel,
            )
            .id(albumId)
        } else if let albumId = navigationCoordinator.selectedAlbumId {
            AlbumDetailView(
                albumId: albumId,
                playbackViewModel: playbackViewModel,
            )
            .id(albumId)
        } else {
            Text("empty.select_album")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var artistDetailView: some View {
        if let artistId = navigationCoordinator.selectedArtistId,
           let artist = store.artists[artistId]
        {
            ArtistDetailView(
                artist: artist,
                playbackViewModel: playbackViewModel,
            )
            .id(artistId)
        } else if let artistId = navigationCoordinator.selectedArtistId {
            ArtistDetailView(
                artistId: artistId,
                playbackViewModel: playbackViewModel,
            )
            .id(artistId)
        } else {
            Text("empty.select_artist")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playlistDetailView: some View {
        if let playlistId = navigationCoordinator.selectedPlaylistId,
           let playlist = store.playlists[playlistId]
        {
            PlaylistDetailView(
                playlist: playlist,
                playbackViewModel: playbackViewModel,
            )
            .id(playlistId)
        } else if let playlistId = navigationCoordinator.selectedPlaylistId {
            PlaylistDetailView(
                playlistId: playlistId,
                playbackViewModel: playbackViewModel,
            )
            .id(playlistId)
        } else {
            Text("empty.select_playlist")
                .foregroundStyle(.secondary)
        }
    }
}
