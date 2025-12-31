//
//  FavoritesListView.swift
//  Spotifly
//
//  Displays user's saved tracks (favorites)
//

import SwiftUI

struct FavoritesListView: View {
    let authResult: SpotifyAuthResult
    @Bindable var favoritesViewModel: FavoritesViewModel
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            if favoritesViewModel.isLoading, favoritesViewModel.tracks.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading favorites...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = favoritesViewModel.errorMessage, favoritesViewModel.tracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Failed to load favorites")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task {
                            await favoritesViewModel.loadTracks(accessToken: authResult.accessToken)
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
                    Text("No favorites yet")
                        .font(.headline)
                    Text("Like songs in the Spotify app to see them here")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(favoritesViewModel.tracks.enumerated()), id: \.element.id) { index, track in
                            FavoriteTrackRow(
                                track: track,
                                trackIndex: index,
                                allTracks: favoritesViewModel.tracks,
                                favoritesViewModel: favoritesViewModel,
                                playbackViewModel: playbackViewModel,
                                accessToken: authResult.accessToken,
                            )
                        }

                        // Load more indicator
                        if favoritesViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await favoritesViewModel.loadMoreIfNeeded(accessToken: authResult.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await favoritesViewModel.refresh(accessToken: authResult.accessToken)
                }
            }
        }
        .task {
            if favoritesViewModel.tracks.isEmpty, !favoritesViewModel.isLoading {
                await favoritesViewModel.loadTracks(accessToken: authResult.accessToken)
            }
        }
    }
}

struct FavoriteTrackRow: View {
    let track: SavedTrack
    let trackIndex: Int
    let allTracks: [SavedTrack]
    @Bindable var favoritesViewModel: FavoritesViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String

    var body: some View {
        HStack(spacing: 12) {
            // Album art
            if let imageURL = track.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 50, height: 50)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .cornerRadius(4)
                    case .failure:
                        Image(systemName: "music.note")
                            .font(.title3)
                            .frame(width: 50, height: 50)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.title3)
                    .frame(width: 50, height: 50)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            // Track info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(track.albumName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Duration
            Text(formatDuration(track.durationMs))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Unfavorite button
            Button {
                Task {
                    await favoritesViewModel.unfavoriteTrack(trackId: track.id, accessToken: accessToken)
                }
            } label: {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            // Play button
            Button {
                Task {
                    playTrackAndFollowing()
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(playbackViewModel.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
        .onTapGesture(count: 2) {
            // Double-click to play this track and all following
            playTrackAndFollowing()
        }
    }

    private func playTrackAndFollowing() {
        // Get all track URIs from current track onwards
        let tracksToPlay = Array(allTracks[trackIndex...])
        let urisToPlay = tracksToPlay.map { $0.uri }

        Task {
            await playbackViewModel.playTracks(urisToPlay, accessToken: accessToken)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
