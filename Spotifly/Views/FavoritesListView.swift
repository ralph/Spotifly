//
//  FavoritesListView.swift
//  Spotifly
//
//  Displays user's saved tracks (favorites)
//

import SwiftUI

struct FavoritesListView: View {
    @Environment(SpotifySession.self) private var session
    @Bindable var favoritesViewModel: FavoritesViewModel
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            if favoritesViewModel.isLoading, favoritesViewModel.tracks.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.favorites")
                        .foregroundStyle(.secondary)
                }
            } else if let error = favoritesViewModel.errorMessage, favoritesViewModel.tracks.isEmpty {
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
                            await favoritesViewModel.loadTracks(accessToken: session.accessToken)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if favoritesViewModel.tracks.isEmpty {
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
                        ForEach(Array(favoritesViewModel.tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track.toTrackRowData(),
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                playbackViewModel: playbackViewModel,
                                accessToken: session.accessToken,
                                initialFavorited: true,
                                onFavoriteChanged: { isFavorited in
                                    if !isFavorited {
                                        favoritesViewModel.removeTrack(id: track.id)
                                    }
                                },
                            )

                            if index < favoritesViewModel.tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 94)
                            }
                        }

                        // Load more indicator
                        if favoritesViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await favoritesViewModel.loadMoreIfNeeded(accessToken: session.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await favoritesViewModel.refresh(accessToken: session.accessToken)
                }
            }
        }
        .task {
            if favoritesViewModel.tracks.isEmpty, !favoritesViewModel.isLoading {
                await favoritesViewModel.loadTracks(accessToken: session.accessToken)
            }
        }
    }
}
