//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist with top tracks, using normalized store
//

import SwiftUI

struct ArtistDetailView: View {
    /// ID is always required (either passed directly or derived from artist object)
    let artistId: String

    /// Optional pre-loaded artist (avoids network request if already have data)
    private let initialArtist: Artist?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService

    @State private var artist: Artist?
    @State private var albums: [Album] = []
    @State private var isLoadingArtist = false
    @State private var isLoadingAlbums = false
    @State private var errorMessage: String?
    @State private var showAllAlbums = false
    @State private var showUnfollowConfirmation = false

    /// Whether this artist is in the user's followed artists
    private var isFollowing: Bool {
        store.userArtistIds.contains(artistId)
    }

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
            await loadAlbums()
        }
        .alert("artist.unfollow.title", isPresented: $showUnfollowConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("artist.unfollow.action", role: .destructive) {
                unfollowArtist()
            }
        } message: {
            Text("artist.unfollow.message \(artist?.name ?? "")")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showArtistUnfollowConfirmation)) { notification in
            if let notificationArtistId = notification.object as? String, notificationArtistId == artistId {
                showUnfollowConfirmation = true
            }
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
                    }
                }
                .padding(.top, 24)

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
                                Button {
                                    withAnimation {
                                        showAllAlbums.toggle()
                                    }
                                } label: {
                                    if showAllAlbums {
                                        Text("artist.show_less")
                                    } else {
                                        Text("artist.show_all \(albums.count)")
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
                                    navigationCoordinator.navigateToAlbumSection(
                                        albumId: album.id,
                                        from: .artists,
                                        selectionId: artistId,
                                    )
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 100)
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

    private func unfollowArtist() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await artistService.unfollowArtist(
                    artistId: artistId,
                    accessToken: token,
                )
                // Navigate away from the unfollowed artist
                navigationCoordinator.clearArtistSelection()
            } catch {
                errorMessage = String(localized: "error.unfollow_artist \(error.localizedDescription)")
            }
        }
    }

    private func followArtist() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await artistService.followArtist(
                    artistId: artistId,
                    accessToken: token,
                )
            } catch {
                errorMessage = String(localized: "error.follow_artist \(error.localizedDescription)")
            }
        }
    }
}
