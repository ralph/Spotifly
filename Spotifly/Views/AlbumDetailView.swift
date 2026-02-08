//
//  AlbumDetailView.swift
//  Spotifly
//
//  Shows details for an album with track list, using normalized store
//

import AppKit
import SwiftUI

struct AlbumDetailView: View {
    /// ID is always required (either passed directly or derived from album object)
    let albumId: String

    /// Optional pre-loaded album (avoids network request if already have data)
    private let initialAlbum: Album?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var album: Album?
    @State private var isLoadingAlbum = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

    /// Initialize with an album ID (fetches album data)
    init(albumId: String, playbackViewModel: PlaybackViewModel) {
        self.albumId = albumId
        initialAlbum = nil
        self.playbackViewModel = playbackViewModel
    }

    /// Initialize with a pre-loaded album (avoids network request)
    init(album: Album, playbackViewModel: PlaybackViewModel) {
        albumId = album.id
        initialAlbum = album
        self.playbackViewModel = playbackViewModel
    }

    /// Tracks from the store for this album
    private var tracks: [Track] {
        guard let storedAlbum = store.albums[albumId] else { return [] }
        return storedAlbum.trackIds.compactMap { store.tracks[$0] }
    }

    /// Whether this album is in the user's library
    private var isInLibrary: Bool {
        store.userAlbumIds.contains(albumId)
    }

    var body: some View {
        Group {
            if let album {
                albumContent(album)
            } else if isLoadingAlbum {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                    Button("action.try_again") {
                        Task { await loadAlbum() }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(album?.name ?? "")
        .task(id: albumId) {
            // Use initial album if provided, otherwise fetch
            if let initialAlbum {
                album = initialAlbum
            } else {
                await loadAlbum()
            }
            await loadTracks()
        }
        .alert("album.remove.title", isPresented: $showRemoveConfirmation) {
            Button("action.cancel", role: .cancel) {}
            Button("album.remove.action", role: .destructive) {
                removeFromLibrary()
            }
        } message: {
            Text("album.remove.message \(album?.name ?? "")")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAlbumRemoveConfirmation)) { notification in
            if let notificationAlbumId = notification.object as? String, notificationAlbumId == albumId {
                showRemoveConfirmation = true
            }
        }
    }

    private func albumContent(_ album: Album) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Album art and metadata
                VStack(spacing: 16) {
                    if let imageURL = album.imageURL {
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
                                    .cornerRadius(8)
                                    .shadow(radius: 10)
                            case .failure:
                                Image(systemName: "music.note")
                                    .font(.system(size: 60))
                                    .frame(width: 200, height: 200)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .frame(width: 200, height: 200)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }

                    VStack(spacing: 8) {
                        Text(album.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)

                        if let artistId = album.artistId {
                            Button {
                                navigationCoordinator.navigateToArtistSection(artistId: artistId, from: .albums, selectionId: albumId)
                            } label: {
                                Text(album.artistName)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                        } else {
                            Text(album.artistName)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 4) {
                            Text(String(format: String(localized: "metadata.tracks"), album.trackCount))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            if !tracks.isEmpty {
                                Text("metadata.separator")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                Text(totalDuration(of: tracks))
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                            if let releaseDate = album.releaseDate {
                                Text("metadata.separator")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                Text(releaseDate)
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // Play All button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("playback.play_album", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(tracks.isEmpty)
                }
                .padding(.top, 24)

                // Track list
                if isLoading {
                    ProgressView("loading.tracks")
                        .padding()
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(
                                track: track,
                                showTrackNumber: true,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                playbackViewModel: playbackViewModel,
                                currentSection: .albums,
                                selectionId: albumId,
                                onDoubleTap: {
                                    let token = await session.validAccessToken()
                                    await playbackViewModel.play(
                                        uriOrUrl: album.uri,
                                        trackIndex: index,
                                        accessToken: token,
                                    )
                                },
                            )

                            if index < tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private func loadAlbum() async {
        isLoadingAlbum = true
        errorMessage = nil

        let token = await session.validAccessToken()
        do {
            let albumEntity = try await albumService.fetchAlbumDetails(
                albumId: albumId,
                accessToken: token,
            )
            album = albumEntity
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingAlbum = false
    }

    private func loadTracks() async {
        isLoading = true
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            // Load tracks via service (stores them in AppStore)
            _ = try await albumService.getAlbumTracks(
                albumId: albumId,
                accessToken: token,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func playAllTracks() {
        guard let album else { return }
        Task {
            let token = await session.validAccessToken()
            // Use album URI to load via Spirc.load(LoadRequest::from_context_uri())
            // This properly loads the album context instead of individual tracks
            await playbackViewModel.play(uriOrUrl: album.uri, accessToken: token)
        }
    }

    private func removeFromLibrary() {
        Task {
            do {
                let token = await session.validAccessToken()
                try await albumService.removeAlbumFromLibrary(
                    albumId: albumId,
                    accessToken: token,
                )
                // Navigate away from the removed album
                navigationCoordinator.clearAlbumSelection()
            } catch {
                errorMessage = String(localized: "error.remove_album \(error.localizedDescription)")
            }
        }
    }
}
