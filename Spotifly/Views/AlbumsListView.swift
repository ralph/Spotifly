//
//  AlbumsListView.swift
//  Spotifly
//
//  Displays user's saved albums
//

import SwiftUI

struct AlbumsListView: View {
    let authResult: SpotifyAuthResult
    @Bindable var albumsViewModel: AlbumsViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Binding var selectedAlbum: AlbumSimplified?

    var body: some View {
        Group {
            if albumsViewModel.isLoading, albumsViewModel.albums.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading albums...")
                        .foregroundStyle(.secondary)
                }
            } else if let error = albumsViewModel.errorMessage, albumsViewModel.albums.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Failed to load albums")
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task {
                            await albumsViewModel.loadAlbums(accessToken: authResult.accessToken)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if albumsViewModel.albums.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No saved albums")
                        .font(.headline)
                    Text("Save albums in the Spotify app")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(albumsViewModel.albums) { album in
                            AlbumRow(
                                album: album,
                                playbackViewModel: playbackViewModel,
                                accessToken: authResult.accessToken,
                                selectedAlbum: $selectedAlbum
                            )
                        }

                        // Load more indicator
                        if albumsViewModel.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await albumsViewModel.loadMoreIfNeeded(accessToken: authResult.accessToken)
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await albumsViewModel.refresh(accessToken: authResult.accessToken)
                }
            }
        }
        .task {
            if albumsViewModel.albums.isEmpty, !albumsViewModel.isLoading {
                await albumsViewModel.loadAlbums(accessToken: authResult.accessToken)
            }
        }
    }
}

struct AlbumRow: View {
    let album: AlbumSimplified
    @Bindable var playbackViewModel: PlaybackViewModel
    let accessToken: String
    @Binding var selectedAlbum: AlbumSimplified?

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
                    Text("\(album.trackCount) tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(album.releaseDate.prefix(4))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(album.albumType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Play button
            Button {
                Task {
                    await playbackViewModel.play(uriOrUrl: album.uri, accessToken: accessToken)
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
            selectedAlbum = album
        }
    }
}
