//
//  AlbumsListView.swift
//  Spotifly
//
//  Displays user's saved albums using normalized store
//

import SwiftUI

struct AlbumsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    let playbackViewModel: PlaybackViewModel

    /// The ephemeral album being viewed (if not in user's library)
    private var ephemeralAlbum: Album? {
        guard let viewingId = navigationCoordinator.viewingAlbumId,
              !store.userAlbumIds.contains(viewingId),
              let album = store.albums[viewingId]
        else {
            return nil
        }
        return album
    }

    var body: some View {
        LibraryListView(
            items: store.userAlbums,
            ephemeral: ephemeralAlbum,
            pagination: store.albumsPagination,
            selectedId: navigationCoordinator.selectedAlbumId,
            select: { albumId, recordsHistory in
                navigationCoordinator.selectAlbum(albumId, recordsHistory: recordsHistory)
            },
            load: albumService.loadUserAlbums(forceRefresh:),
            loadMore: albumService.loadMoreAlbums,
            style: LibrarySectionStyle(
                loadingText: "loading.albums",
                errorTitle: "error.load_albums",
                emptyTitle: "empty.no_albums",
                emptyMessage: "empty.no_albums.description",
                emptyGlyph: "square.stack",
                placeholderGlyph: "square.stack",
                artworkShape: AnyShape(.rect(cornerRadius: 4)),
            ),
            playbackViewModel: playbackViewModel,
        )
    }
}
