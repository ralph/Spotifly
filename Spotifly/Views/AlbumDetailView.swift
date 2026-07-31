//
//  AlbumDetailView.swift
//  Spotifly
//
//  Shows details for an album with track list, using normalized store
//

import AppKit
import SwiftUI

struct AlbumDetailView: View {
    let albumId: String

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(TrackService.self) private var trackService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.displayScale) private var displayScale

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

    /// The album from the store — the only copy. Whatever a load puts there shows
    /// up here, including a load whose original view was torn down mid-flight.
    private var album: Album? {
        store.albums[albumId]
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
            await loadAlbum()
        }
        .task(id: tracks.map(\.id).joined()) {
            await resolveFavoriteStatusesForTracks()
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
                    if let url = album.images.url(for: 200, scale: displayScale) {
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
                                    .clipShape(.rect(cornerRadius: 8))
                                    .shadow(radius: 10)
                            case .failure:
                                Image(systemName: "music.note")
                                    .font(.system(size: 60))
                                    .frame(width: 200, height: 200)
                                    .background(Color.gray.opacity(0.2))
                                    .clipShape(.rect(cornerRadius: 8))
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .frame(width: 200, height: 200)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(.rect(cornerRadius: 8))
                    }

                    VStack(spacing: 8) {
                        Text(album.name)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)

                        if let artistId = album.artistId {
                            Button {
                                navigationCoordinator.navigateToArtistSection(artistId: artistId)
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
                            Text(localizedNumberString("metadata.tracks", album.trackCount))
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
                    InlineLoadError(message: errorMessage) {
                        await loadAlbum()
                    }
                } else if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tracks.enumerated(), id: \.offset) { index, track in
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
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private func loadAlbum() async {
        // Only claim to be loading when the track list is actually missing —
        // a cached album must not flash a spinner over its tracks.
        isLoading = store.albums[albumId]?.tracksLoaded != true
        errorMessage = nil

        do {
            try await albumService.ensureAlbumLoaded(albumId: albumId)
        } catch {
            // A cancellation is this view going away, not a failure: the load keeps
            // running and its result is in the store for whatever replaces us.
            if !isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func resolveFavoriteStatusesForTracks() async {
        guard !tracks.isEmpty else { return }

        await trackService.ensureFavoriteStatuses(trackIds: tracks.map(\.id))
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
