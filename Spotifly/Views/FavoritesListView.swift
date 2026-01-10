//
//  FavoritesListView.swift
//  Spotifly
//
//  Displays user's saved tracks (favorites) using normalized store
//

import SwiftUI

struct FavoritesListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.favoritesPagination.isLoading, store.favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.favorites")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, store.favoriteTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_favorites")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadFavorites(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
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
                        ForEach(Array(store.favoriteTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track.toTrackRowData(),
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                playbackViewModel: playbackViewModel,
                                currentSection: .favorites,
                            )

                            if index < store.favoriteTracks.count - 1 {
                                Divider()
                                    .padding(.leading, 94)
                            }
                        }

                        // Load more indicator
                        if store.favoritesPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMoreFavorites()
                                    }
                                }
                        }
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

    private func loadFavorites(forceRefresh: Bool = false) async {
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            try await trackService.loadFavorites(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreFavorites() async {
        do {
            let token = await session.validAccessToken()
            try await trackService.loadMoreFavorites(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
