//
//  PlaylistsListView.swift
//  Spotifly
//
//  Displays user's playlists using normalized store
//

import SwiftUI

struct PlaylistsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(PlaylistService.self) private var playlistService
    @Bindable var playbackViewModel: PlaybackViewModel

    // Selection uses playlist ID, looked up from store
    @Binding var selectedPlaylistId: String?

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.playlistsPagination.isLoading, store.userPlaylists.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.playlists")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, store.userPlaylists.isEmpty {
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
                            await loadPlaylists(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if store.userPlaylists.isEmpty {
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
                        ForEach(store.userPlaylists) { playlist in
                            PlaylistRow(
                                playlist: playlist,
                                playbackViewModel: playbackViewModel,
                                isSelected: selectedPlaylistId == playlist.id,
                                onSelect: {
                                    selectedPlaylistId = playlist.id
                                },
                            )
                        }

                        // Load more indicator
                        if store.playlistsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMorePlaylists()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadPlaylists(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userPlaylists.isEmpty, !store.playlistsPagination.isLoading {
                await loadPlaylists()
            }
            // Set initial selection after loading or if already loaded
            if selectedPlaylistId == nil, let first = store.userPlaylists.first {
                selectedPlaylistId = first.id
            }
        }
        .onChange(of: store.userPlaylists) { _, playlists in
            if selectedPlaylistId == nil, let first = playlists.first {
                selectedPlaylistId = first.id
            }
        }
    }

    private func loadPlaylists(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            try await playlistService.loadUserPlaylists(
                accessToken: session.accessToken,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMorePlaylists() async {
        do {
            try await playlistService.loadMorePlaylists(accessToken: session.accessToken)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

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
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.05))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
