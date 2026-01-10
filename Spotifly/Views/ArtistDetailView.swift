//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist with top tracks, using normalized store
//

import SwiftUI

struct ArtistDetailView: View {
    // ID is always required (either passed directly or derived from artist object)
    let artistId: String

    // Optional pre-loaded artist (avoids network request if already have data)
    private let initialArtist: Artist?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService

    @State private var artist: Artist?
    @State private var topTracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var isLoadingArtist = false
    @State private var isLoading = false
    @State private var isLoadingAlbums = false
    @State private var errorMessage: String?
    @State private var showAllAlbums = false

    /// Initialize with an artist ID (fetches artist data)
    init(artistId: String, playbackViewModel: PlaybackViewModel) {
        self.artistId = artistId
        initialArtist = nil
        self.playbackViewModel = playbackViewModel
    }

    /// Initialize with a pre-loaded artist (avoids network request)
    init(artist: Artist, playbackViewModel: PlaybackViewModel) {
        artistId = artist.id
        initialArtist = artist
        self.playbackViewModel = playbackViewModel
    }

    var body: some View {
        Group {
            if let artist {
                artistContent(artist)
            } else if isLoadingArtist {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("action.try_again") {
                        Task { await loadArtist() }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(artist?.name ?? "")
        .task(id: artistId) {
            // Use initial artist if provided, otherwise fetch
            if let initialArtist {
                artist = initialArtist
            } else {
                await loadArtist()
            }
            await loadTopTracks()
            await loadAlbums()
        }
    }

    private func artistContent(_ artist: Artist) -> some View {
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

                        if let followers = artist.followers {
                            Text(String(format: String(localized: "metadata.followers"), formatFollowers(followers)))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
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

                        let displayedTracks = Array(topTracks.prefix(5))
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    track: track.toTrackRowData(),
                                    index: index,
                                    currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                    playbackViewModel: playbackViewModel,
                                )

                                if track.id != displayedTracks.last?.id {
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
                                    navigationCoordinator.navigateToAlbum(albumId: album.id)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// A card view for displaying an album in the grid
    private struct AlbumCard: View {
        let album: Album
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

        private func formatReleaseYear(_ dateString: String?) -> String {
            guard let dateString else { return "" }
            return String(dateString.prefix(4))
        }
    }

    private func loadArtist() async {
        isLoadingArtist = true
        errorMessage = nil

        let token = await session.validAccessToken()
        do {
            let artistEntity = try await artistService.fetchArtistDetails(
                artistId: artistId,
                accessToken: token,
            )
            artist = artistEntity
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingArtist = false
    }

    private func loadTopTracks() async {
        topTracks = []
        isLoading = true
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            // Load via service (stores tracks in AppStore)
            topTracks = try await artistService.fetchArtistTopTracks(
                artistId: artistId,
                accessToken: token,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadAlbums() async {
        albums = []
        isLoadingAlbums = true

        do {
            let token = await session.validAccessToken()
            // Load via service (stores albums in AppStore)
            albums = try await artistService.fetchArtistAlbums(
                artistId: artistId,
                accessToken: token,
            )
        } catch {
            // Silently fail for albums - not critical
        }

        isLoadingAlbums = false
    }

    private func playAllTopTracks() {
        Task {
            let token = await session.validAccessToken()
            await playbackViewModel.playTracks(
                topTracks.map(\.uri),
                accessToken: token,
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
