//
//  LoggedInDetailRouterView.swift
//  Spotifly
//
//  Routes the logged-in detail column for three-column library sections.
//

import SwiftUI

struct LoggedInDetailRouterView: View {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    let playbackViewModel: PlaybackViewModel

    // Each branch used to pick between an `init(album:)` and an `init(albumId:)`
    // depending on whether the entity was in the store yet. Those are the two
    // branches of a `_ConditionalContent` and so have distinct structural
    // identities — `.id()` does not unify them — which meant that the moment the
    // entity landed in the store SwiftUI destroyed the view that was fetching it
    // and cancelled its `.task` mid-request. The detail views read the store
    // directly now, so one branch is all any of them needs.

    var body: some View {
        switch navigationCoordinator.selectedNavigationItem {
        case .albums:
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

        case .artists:
            if let artistId = navigationCoordinator.selectedArtistId {
                ArtistDetailView(artistId: artistId)
                    .id(artistId)
            } else {
                Text("empty.select_artist")
                    .foregroundStyle(.secondary)
            }

        case .playlists:
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

        default:
            EmptyView()
        }
    }
}
