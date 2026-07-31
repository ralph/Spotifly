//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist with top tracks, using normalized store
//

import SwiftUI

struct ArtistDetailView: View {
    let artistId: String

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService
    @Environment(\.displayScale) private var displayScale

    @State private var isLoadingAlbums = false
    @State private var errorMessage: String?
    @State private var showAllAlbums = false
    @State private var showUnfollowConfirmation = false

    /// The artist from the store — the only copy. Whatever a load puts there shows
    /// up here, including a load whose original view was torn down mid-flight.
    private var artist: Artist? {
        store.artists[artistId]
    }

    /// The artist's albums, cached in the store rather than re-fetched per visit.
    private var albums: [Album] {
        store.albums(forArtist: artistId) ?? []
    }

    /// Whether this artist is in the user's followed artists
    private var isFollowing: Bool {
        store.userArtistIds.contains(artistId)
    }

    var body: some View {
        Group {
            if let artist {
                artistContent(artist)
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
            await loadArtist()
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
                    if let url = artist.images.url(for: 200, scale: displayScale) {
                        AsyncImage(url: url) { phase in
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
                            .bold()
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
                } else if let errorMessage {
                    InlineLoadError(message: errorMessage) {
                        await loadArtist()
                    }
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
                                    navigationCoordinator.navigateToAlbumSection(albumId: album.id)
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

        @Environment(\.displayScale) private var displayScale

        var body: some View {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = album.images.url(for: 150, scale: displayScale) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 150, height: 150)
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 150, height: 150)
                                    .clipShape(.rect(cornerRadius: 8))
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
                            .font(.subheadline.weight(.medium))
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
                .clipShape(.rect(cornerRadius: 8))
        }

        private func formatReleaseYear(_ dateString: String?) -> String {
            guard let dateString else { return "" }
            return String(dateString.prefix(4))
        }
    }

    private func loadArtist() async {
        // Only claim to be loading when the album list is actually missing —
        // a cached artist must not flash a spinner over their albums.
        isLoadingAlbums = store.artistAlbumIds[artistId] == nil
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            try await artistService.ensureArtistLoaded(artistId: artistId, accessToken: token)
        } catch {
            // A cancellation is this view going away, not a failure: the load keeps
            // running and its result is in the store for whatever replaces us.
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
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
