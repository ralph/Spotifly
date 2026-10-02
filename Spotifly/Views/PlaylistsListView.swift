//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists using normalized store
//

import SwiftUI

struct PlaylistsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    /// The ephemeral playlist being viewed (if not in user's library)
    private var ephemeralPlaylist: Playlist? {
        guard let viewingId = navigationCoordinator.viewingPlaylistId,
              !store.userPlaylistIds.contains(viewingId),
              !store.playlistOutline.contains(where: { $0.item.playlistId == viewingId }),
              let playlist = store.playlists[viewingId]
        else {
            return nil
        }
        return playlist
    }

    var body: some View {
        LibraryListView(
            items: store.userPlaylists,
            ephemeral: ephemeralPlaylist,
            pagination: store.playlistsPagination,
            selectedId: navigationCoordinator.selectedPlaylistId,
            select: { playlistId, recordsHistory in
                navigationCoordinator.selectPlaylist(playlistId, recordsHistory: recordsHistory)
            },
            load: playlistService.loadUserPlaylists(forceRefresh:),
            loadMore: playlistService.loadMorePlaylists,
            style: LibrarySectionStyle(
                loadingText: "loading.playlists",
                errorTitle: "error.load_playlists",
                emptyTitle: "empty.no_playlists",
                emptyMessage: "empty.no_playlists.description",
                emptyGlyph: "music.note.list",
                placeholderGlyph: "music.note.list",
                artworkShape: AnyShape(.rect(cornerRadius: 4)),
            ),
            outline: Self.outline(store.playlistOutline, playlists: store.playlists),
        )
        .task {
            try? await playlistService.loadPlaylistOutline()
        }
    }

    /// The playlists in their folders, as the section shows them, or nil without any folders.
    static func outline(_ rows: [PlaylistOutlineRow], playlists: [String: Playlist]) -> [LibraryOutlineRow<Playlist>]? {
        guard !rows.isEmpty else { return nil }
        return rows.compactMap { row in
            switch row.item {
            case let .folder(uri, name):
                .folder(uri: uri, name: name, depth: row.depth)
            case let .playlist(id):
                playlists[id].map { .entity($0, depth: row.depth) }
            }
        }
    }
}
