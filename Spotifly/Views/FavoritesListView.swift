//
//  FavoritesListView.swift
//  Spotifly
//
//  Displays user's saved tracks (favorites) using normalized store
//

import SwiftUI

struct FavoritesListView: View {
    /// What the toolbar's field filters the list by, on this page.
    var filter = ""

    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if store.favoritesPagination.isLoading, store.favoriteTracks.isEmpty {
                ProgressView("loading.favorites")
            } else if let failure = store.favoritesPagination.failure, store.favoriteTracks.isEmpty {
                ContentUnavailableView {
                    Label("error.load_favorites", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("action.try_again") {
                        Task {
                            await loadFavorites(forceRefresh: true)
                        }
                    }
                    .retryingWhenNetworkReturns {
                        await loadFavorites(forceRefresh: true)
                    }
                }
            } else if store.favoriteTracks.isEmpty {
                ContentUnavailableView(
                    "empty.no_favorites",
                    systemImage: "heart",
                    description: Text("empty.no_favorites.description"),
                )
            } else {
                VStack(spacing: 0) {
                    header
                    // A later page that failed leaves the list short, which sorting and the filter
                    // would hide; it says so, with a retry, over the rows there are.
                    if let failure = store.favoritesPagination.failure {
                        InlineLoadError(failure: failure) {
                            await trackService.loadAllFavorites()
                        }
                        .padding(.bottom, 8)
                    }
                    TrackTable(
                        rows: rows,
                        columns: [.number, .album, .added],
                        currentSection: .favorites,
                    ) { row in
                        Task {
                            // The playlist the list was read from; see `LikedSongs`.
                            await playbackViewModel.play(
                                uriOrUrl: LikedSongs.uri,
                                trackIndex: row.number - 1,
                                startingAtUri: row.track.uri,
                            )
                        }
                    }
                }
            }
        }
        .task {
            if store.favoriteTracks.isEmpty, !store.favoritesPagination.isLoading {
                await loadFavorites()
            }
        }
        // Whenever pages are pending, on opening and again after a refresh, which starts over
        // with the first.
        .task(id: store.favoritesPagination.hasMore && store.favoritesPagination.isLoaded) {
            await trackService.loadAllFavorites()
        }
    }

    /// Every favorite, numbered as Liked Songs lists them, then narrowed by the filter.
    private var rows: [TrackTableRow] {
        let all = store.favoriteTracks.enumerated().map { index, track in
            TrackTableRow(id: track.id, number: index + 1, track: track, addedAt: store.favoriteAddedAt[track.id])
        }
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.track.name.localizedStandardContains(query)
                || $0.track.artistName.localizedStandardContains(query)
                || $0.album.localizedStandardContains(query)
        }
    }

    private var header: some View {
        let tracks = store.favoriteTracks
        return DetailHeader(kind: String(localized: "detail.kind.playlist"), title: String(localized: "nav.favorites")) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [Color(red: 1, green: 0.56, blue: 0.64), Color(red: 0.88, green: 0.14, blue: 0.37)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing,
                ))
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white)
                }
        } metadata: {
            // Of the whole list, as Spotify counts it, rather than of the pages loaded so far.
            Text(verbatim: metadataLine(
                localizedNumberString("metadata.tracks", max(store.favoritesPagination.total, tracks.count)),
                totalDuration(of: tracks),
            ))
        } actions: {
            PlayAndShuffleButtons {
                Task { await playbackViewModel.play(uriOrUrl: LikedSongs.uri) }
            } shuffle: {
                Task { await playbackViewModel.playShuffled(uriOrUrl: LikedSongs.uri, trackUris: tracks.map(\.uri)) }
            }
            .disabled(tracks.isEmpty)
        }
    }

    /// A failure is recorded on `favoritesPagination`, where the toolbar's refresh leaves it too.
    private func loadFavorites(forceRefresh: Bool = false) async {
        try? await trackService.loadFavorites(forceRefresh: forceRefresh)
    }
}
