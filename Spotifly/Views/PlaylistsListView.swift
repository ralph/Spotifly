//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists
//

import SwiftUI

struct PlaylistsListView: View {
    let authResult: SpotifyAuthResult
    @Bindable var playlistsViewModel: PlaylistsViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Binding var selectedPlaylist: PlaylistSimplified?

    var body: some View {
        Group {
            if playlistsViewModel.isLoading, playlistsViewModel.playlists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading playlists...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = playlistsViewModel.errorMessage, playlistsViewModel.playlists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Failed to load playlists")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task {
                            await playlistsViewModel.loadPlaylists(accessToken: authResult.accessToken)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if playlistsViewModel.playlists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No playlists found")
                        .font(.headline)
                    Text("Create playlists in the Spotify app")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(playlistsViewModel.playlists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                playbackViewModel: playbackViewModel,
                                accessToken: authResult.accessToken,
                                selectedPlaylist: $selectedPlaylist,
                            )
                        }

                        // Load more indicator
                        if playlistsViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await playlistsViewModel.loadMoreIfNeeded(accessToken: authResult.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await playlistsViewModel.refresh(accessToken: authResult.accessToken)
                }
            }
        }
        .task {
            if playlistsViewModel.playlists.isEmpty, !playlistsViewModel.isLoading {
                await playlistsViewModel.loadPlaylists(accessToken: authResult.accessToken)
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistSimplified
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String
    @Binding var selectedPlaylist: PlaylistSimplified?

    var body: some View {
        HStack(spacing: 12) {
            // Playlist image
            if let imageURL = playlist.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: 60, height: 60)
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .cornerRadius(6)
                    case .failure:
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .frame(width: 60, height: 60)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
            }

            // Playlist info
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text("\(playlist.trackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(playlist.ownerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Play button
            Button {
                Task {
                    await playbackViewModel.play(uriOrUrl: playlist.uri, accessToken: accessToken)
                }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(playbackViewModel.isLoading)
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlaylist = playlist
        }
    }
}
