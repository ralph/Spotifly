//
//  LoggedInDetailRouterView.swift
//  Spotifly
//
//  Routes the logged-in detail column for three-column library sections.
//

import SwiftUI

struct LoggedInDetailRouterView: View {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
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

    // Each of these used to pick between an `init(album:)` and an `init(albumId:)`
    // depending on whether the entity was in the store yet. Those are the two
    // branches of a `_ConditionalContent` and so have distinct structural
    // identities — `.id()` does not unify them — which meant that the moment the
    // entity landed in the store SwiftUI destroyed the view that was fetching it
    // and cancelled its `.task` mid-request. The detail views read the store
    // directly now, so one branch is all any of them needs.

    @ViewBuilder
    private var albumDetailView: some View {
        if let albumId = navigationCoordinator.selectedAlbumId {
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
        if let artistId = navigationCoordinator.selectedArtistId {
            ArtistDetailView(artistId: artistId)
                .id(artistId)
        } else {
            Text("empty.select_artist")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playlistDetailView: some View {
        if let playlistId = navigationCoordinator.selectedPlaylistId {
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
