//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist search result with top tracks
//

import SwiftUI

struct ArtistDetailView: View {
    let artist: SearchArtist
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var topTracks: [SearchTrack] = []
    @State private var albums: [SearchAlbum] = []
    @State private var isLoading = false
    @State private var isLoadingAlbums = false
    @State private var errorMessage: String?
    @State private var showAllAlbums = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Artist image and metadata
                VStack(spacing: 16) {
                    if let imageURL = artist.imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 200, height: 200)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 200, height: 200)
                                    .clipShape(Circle())
                                    .shadow(radius: 10)
                            case .failure:
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .frame(width: 200, height: 200)
                                    .foregroundStyle(.gray.opacity(0.3))
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .frame(width: 200, height: 200)
                            .foregroundStyle(.gray.opacity(0.3))
                    }

                    VStack(spacing: 8) {
                        Text(artist.name)
                            .font(.title)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)

                        if !artist.genres.isEmpty {
                            Text(artist.genres.prefix(3).joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Text(String(format: String(localized: "metadata.followers"), formatFollowers(artist.followers)))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // Play Top Tracks button
                    Button {
                        playAllTopTracks()
                    } label: {
                        Label("playback.play_top_tracks", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(topTracks.isEmpty)
                }
                .padding(.top, 24)

                // Top Tracks
                if isLoading {
                    ProgressView("loading.top_tracks")
                        .padding()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("section.top_tracks")
                            .font(.headline)
                            .padding(.horizontal)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    track: track.toTrackRowData(),
                                    index: index,
                                    currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                    playbackViewModel: playbackViewModel,
                                    accessToken: session.accessToken,
                                )

                                if track.id != topTracks.last?.id {
                                    Divider()
                                        .padding(.leading, 94)
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }

                // Albums Section
                if isLoadingAlbums {
                    ProgressView("loading.albums")
                        .padding()
                } else if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("section.albums")
                                .font(.headline)

                            Spacer()

                            if albums.count > 5 {
                                Button(showAllAlbums ? "Show Less" : "Show All (\(albums.count))") {
                                    withAnimation {
                                        showAllAlbums.toggle()
                                    }
                                }
                                .font(.subheadline)
                                .foregroundStyle(.green)
                            }
                        }
                        .padding(.horizontal)

                        let displayedAlbums = showAllAlbums ? albums : Array(albums.prefix(5))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 16) {
                            ForEach(displayedAlbums) { album in
                                AlbumCard(album: album) {
                                    navigationCoordinator.navigateToAlbum(
                                        albumId: album.id,
                                        accessToken: session.accessToken,
                                    )
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .task {
            await loadTopTracks()
            await loadAlbums()
        }
    }

    /// A card view for displaying an album in the grid
    private struct AlbumCard: View {
        let album: SearchAlbum
        let onTap: () -> Void

        var body: some View {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    if let imageURL = album.imageURL {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 150, height: 150)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 150, height: 150)
                                    .cornerRadius(8)
                            case .failure:
                                albumPlaceholder
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        albumPlaceholder
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(formatReleaseYear(album.releaseDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }

        private var albumPlaceholder: some View {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.gray)
                .frame(width: 150, height: 150)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
        }

        private func formatReleaseYear(_ dateString: String) -> String {
            // Release date can be "2023", "2023-05", or "2023-05-15"
            String(dateString.prefix(4))
        }
    }

    private func loadTopTracks() async {
        guard topTracks.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            topTracks = try await SpotifyAPI.fetchArtistTopTracks(
                accessToken: session.accessToken,
                artistId: artist.id,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadAlbums() async {
        guard albums.isEmpty else { return }

        isLoadingAlbums = true

        do {
            albums = try await SpotifyAPI.fetchArtistAlbums(
                accessToken: session.accessToken,
                artistId: artist.id,
            )
        } catch {
            // Silently fail for albums - not critical
        }

        isLoadingAlbums = false
    }

    private func playAllTopTracks() {
        Task {
            await playbackViewModel.playTracks(
                topTracks.map(\.uri),
                accessToken: session.accessToken,
            )
        }
    }

    private func formatFollowers(_ count: Int) -> String {
        if count >= 1_000_000 {
            String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1000 {
            String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            "\(count)"
        }
    }
}
