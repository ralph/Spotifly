//
//  AlbumsListView.swift
//  Spotifly
//
//  Displays user's saved albums using normalized store
//

import SwiftUI

struct AlbumsListView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Bindable var playbackViewModel: PlaybackViewModel

    // Selection uses album ID, looked up from store
    @Binding var selectedAlbumId: String?

    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.albumsPagination.isLoading, store.userAlbums.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("loading.albums")
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, store.userAlbums.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("error.load_albums")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadAlbums(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if store.userAlbums.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("empty.no_albums")
                        .font(.headline)
                    Text("empty.no_albums.description")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.userAlbums) { album in
                            AlbumRow(
                                album: album,
                                playbackViewModel: playbackViewModel,
                                isSelected: selectedAlbumId == album.id,
                                onSelect: {
                                    selectedAlbumId = album.id
                                },
                            )
                        }

                        // Load more indicator
                        if store.albumsPagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMoreAlbums()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadAlbums(forceRefresh: true)
                }
            }
        }
        .task {
            if store.userAlbums.isEmpty, !store.albumsPagination.isLoading {
                await loadAlbums()
            }
            // Set initial selection after loading or if already loaded
            if selectedAlbumId == nil, let first = store.userAlbums.first {
                selectedAlbumId = first.id
            }
        }
        .onChange(of: store.userAlbums) { _, albums in
            if selectedAlbumId == nil, let first = albums.first {
                selectedAlbumId = first.id
            }
        }
    }

    private func loadAlbums(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            let token = await session.validAccessToken()
            try await albumService.loadUserAlbums(
                accessToken: token,
                forceRefresh: forceRefresh,
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreAlbums() async {
        do {
            let token = await session.validAccessToken()
            try await albumService.loadMoreAlbums(accessToken: token)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AlbumRow: View {
    let album: Album
    @Bindable var playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(SpotifySession.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            // Album cover
            if let imageURL = album.imageURL {
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
                        Image(systemName: "square.stack")
                            .font(.title2)
                            .frame(width: 60, height: 60)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Image(systemName: "square.stack")
                    .font(.title2)
                    .frame(width: 60, height: 60)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(6)
            }

            // Album info
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(album.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(String(format: String(localized: "metadata.tracks"), album.trackCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let duration = album.formattedDuration {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let releaseDate = album.releaseDate {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(releaseDate.prefix(4))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let albumType = album.albumType {
                        Text("metadata.separator")
                            .foregroundStyle(.secondary)

                        Text(albumType.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Play button
            Button {
                Task {
                    let token = await session.validAccessToken()
                    await playbackViewModel.play(uriOrUrl: album.uri, accessToken: token)
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
