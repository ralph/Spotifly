//
//  FavoritesListView.swift
//  Spotifly
//
//  Displays user's saved tracks (favorites) using normalized store
//

import SwiftUI

struct FavoritesListView: View {
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if store.favoritesPagination.isLoading, store.favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.favorites")
                        .foregroundStyle(.secondary)
                }
            } else if let failure = store.favoritesPagination.failure, store.favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_favorites")
                        .font(.headline)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadFavorites(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .retryingWhenNetworkReturns {
                        await loadFavorites(forceRefresh: true)
                    }
                }
                .padding()
            } else if store.favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "heart")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_favorites")
                        .font(.headline)
                    Text("empty.no_favorites.description")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.favoriteTracks.enumerated(), id: \.element.id) { index, track in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 94)
                            }

                            TrackRow(
                                track: track,
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                currentSection: .favorites,
                                onDoubleTap: {
                                    // The playlist the list was read from; see `LikedSongs`.
                                    await playbackViewModel.play(
                                        uriOrUrl: LikedSongs.uri,
                                        trackIndex: index,
                                        startingAtUri: track.uri,
                                    )
                                },
                            )
                        }

                        LoadMoreRow(pagination: store.favoritesPagination, loadMore: loadMoreFavorites)
                    }
                    .padding()
                }
                .refreshable {
                    await loadFavorites(forceRefresh: true)
                }
            }
        }
        .task {
            if store.favoriteTracks.isEmpty, !store.favoritesPagination.isLoading {
                await loadFavorites()
            }
        }
    }

    /// A failure is recorded on `favoritesPagination`, where the toolbar's refresh leaves it too.
    private func loadFavorites(forceRefresh: Bool = false) async {
        try? await trackService.loadFavorites(forceRefresh: forceRefresh)
    }

    private func loadMoreFavorites() async {
        try? await trackService.loadMoreFavorites()
    }
}
