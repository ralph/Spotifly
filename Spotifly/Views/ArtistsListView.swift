//
//  ArtistsListView.swift
//  Spotifly
//
//  Displays user's followed artists using normalized store
//

import SwiftUI

struct ArtistsListView: View {
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    let playbackViewModel: PlaybackViewModel

    /// The ephemeral artist being viewed (if not in user's library)
    private var ephemeralArtist: Artist? {
        guard let viewingId = navigationCoordinator.viewingArtistId,
              !store.userArtistIds.contains(viewingId),
              let artist = store.artists[viewingId]
        else {
            return nil
        }
        return artist
    }

    var body: some View {
        LibraryListView(
            items: store.userArtists,
            ephemeral: ephemeralArtist,
            pagination: store.artistsPagination,
            selectedId: navigationCoordinator.selectedArtistId,
            select: { artistId, recordsHistory in
                navigationCoordinator.selectArtist(artistId, recordsHistory: recordsHistory)
            },
            load: artistService.loadUserArtists(forceRefresh:),
            loadMore: artistService.loadMoreArtists,
            style: LibrarySectionStyle(
                loadingText: "loading.artists",
                errorTitle: "error.load_artists",
                emptyTitle: "empty.no_artists",
                emptyMessage: "empty.no_artists.description",
                emptyGlyph: "person.2",
                placeholderGlyph: "person.fill",
                artworkShape: AnyShape(.circle),
            ),
            playbackViewModel: playbackViewModel,
        )
    }
}
