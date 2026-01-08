//
//  ArtistDetailView.swift
//  Spotifly
//
//  Shows details for an artist with top tracks, using normalized store
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ArtistDetailView: View {
    let artist: SearchArtist
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(AppStore.self) private var store
    @Environment(ArtistService.self) private var artistService

    @State private var topTracks: [Track] = []
    @State private var albums: [Album] = []
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
                        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #else
            .background(Color(UIColor.secondarySystemBackground))
            #endif
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

                        let sortedAlbums = sortedAlbumsWithCurrentFirst
                        let displayedAlbums = showAllAlbums ? sortedAlbums : Array(sortedAlbums.prefix(5))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)], spacing: 16) {
                            ForEach(displayedAlbums) { album in
                                AlbumCard(
                                    album: album,
                                    isCurrentAlbum: album.id == navigationCoordinator.currentAlbum?.id,
                                ) {
                                    // Convert unified Album to SearchAlbum for navigation
                                    let searchAlbum = SearchAlbum(from: album)
                                    navigationCoordinator.navigateToAlbum(searchAlbum, artist: artist)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .task(id: artist.id) {
            await loadTopTracks()
            await loadAlbums()
        }
    }

    /// Albums sorted with current album first (if any)
    private var sortedAlbumsWithCurrentFirst: [Album] {
        guard let currentAlbum = navigationCoordinator.currentAlbum else {
            return albums
        }
        var sorted = albums
        if let index = sorted.firstIndex(where: { $0.id == currentAlbum.id }) {
            let current = sorted.remove(at: index)
            sorted.insert(current, at: 0)
        } else {
            // Current album not in list - convert and prepend
            if let storedAlbum = store.albums[currentAlbum.id] {
                sorted.insert(storedAlbum, at: 0)
            }
        }
        return sorted
    }

    /// A card view for displaying an album in the grid
    private struct AlbumCard: View {
        let album: Album
        let isCurrentAlbum: Bool
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
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.green, lineWidth: isCurrentAlbum ? 3 : 0),
                                    )
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
                            .foregroundStyle(isCurrentAlbum ? .green : .primary)

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
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: isCurrentAlbum ? 3 : 0),
                )
        }

        private func formatReleaseYear(_ dateString: String?) -> String {
            guard let dateString else { return "" }
            return String(dateString.prefix(4))
        }
    }

    private func loadTopTracks() async {
        topTracks = []
        isLoading = true
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            // Load via service (stores tracks in AppStore)
            topTracks = try await artistService.fetchArtistTopTracks(
                artistId: artist.id,
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
                artistId: artist.id,
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
