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
    let playbackViewModel: PlaybackViewModel

    /// The ephemeral playlist being viewed (if not in user's library)
    private var ephemeralPlaylist: Playlist? {
        guard let viewingId = navigationCoordinator.viewingPlaylistId,
              !store.userPlaylistIds.contains(viewingId),
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
            playbackViewModel: playbackViewModel,
            outline: Self.outline(store.playlistOutline, library: store.userPlaylistIds, playlists: store.playlists),
        )
        .task {
            try? await playlistService.loadPlaylistOutline()
        }
    }

    /// The playlists in their folders, as the section shows them, or nil without any folders.
    ///
    /// The outline is loaded once, and the flat list follows every change made here, so the
    /// flat list says which playlists are in the library: one created or followed since goes at
    /// the top, where the flat list puts it, and one deleted or unfollowed since is left out.
    static func outline(
        _ rows: [PlaylistOutlineRow],
        library ids: [String],
        playlists: [String: Playlist],
    ) -> [LibraryOutlineRow<Playlist>]? {
        guard !rows.isEmpty else { return nil }
        let library = Set(ids)
        let outlined = Set(rows.compactMap { row -> String? in
            if case let .playlist(id) = row.item {
                id
            } else {
                nil
            }
        })

        let added = ids.filter { !outlined.contains($0) }.compactMap { playlists[$0] }
            .map { LibraryOutlineRow.entity($0, depth: 0) }
        let nested = rows.compactMap { row -> LibraryOutlineRow<Playlist>? in
            switch row.item {
            case let .folder(uri, name):
                .folder(uri: uri, name: name, depth: row.depth)
            case let .playlist(id):
                library.contains(id) ? playlists[id].map { .entity($0, depth: row.depth) } : nil
            }
        }
        return added + nested
    }
}
