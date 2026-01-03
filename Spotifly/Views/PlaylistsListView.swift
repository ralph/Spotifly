//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists
//

import SwiftUI

struct PlaylistsListView: View {
    @Environment(SpotifySession.self) private var session
    @Bindable var playlistsViewModel: PlaylistsViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Binding var selectedPlaylist: PlaylistSimplified?

    var body: some View {
        Group {
            if playlistsViewModel.isLoading, playlistsViewModel.playlists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.playlists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = playlistsViewModel.errorMessage, playlistsViewModel.playlists.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_playlists")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await playlistsViewModel.loadPlaylists(accessToken: session.accessToken)
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
                    Text("empty.no_playlists")
                        .font(.headline)
                    Text("empty.no_playlists.description")
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
                                selectedPlaylist: $selectedPlaylist,
                            )
                        }

                        // Load more indicator
                        if playlistsViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await playlistsViewModel.loadMoreIfNeeded(accessToken: session.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await playlistsViewModel.refresh(accessToken: session.accessToken)
                }
            }
        }
        .task {
            if playlistsViewModel.playlists.isEmpty, !playlistsViewModel.isLoading {
                await playlistsViewModel.loadPlaylists(accessToken: session.accessToken)
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: PlaylistSimplified
    @Bindable var playbackViewModel: PlaybackViewModel
    @Binding var selectedPlaylist: PlaylistSimplified?
    @Environment(SpotifySession.self) private var session

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
                    Text(String(format: String(localized: "metadata.tracks"), playlist.trackCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = playlist.formattedDuration {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("metadata.separator")
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
                    await playbackViewModel.play(uriOrUrl: playlist.uri, accessToken: session.accessToken)
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
