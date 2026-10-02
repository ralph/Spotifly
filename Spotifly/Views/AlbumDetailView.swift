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

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService
    @Environment(TrackService.self) private var trackService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var isLoading = false
    @State private var failure: LoadFailure?
    @State private var showRemoveConfirmation = false

    /// The album from the store — the only copy. Whatever a load puts there shows
    /// up here, including a load whose original view was torn down mid-flight.
    private var album: Album? {
        store.albums[albumId]
    }

    /// Tracks from the store for this album
    private var tracks: [Track] {
        album?.trackIds.compactMap { store.tracks[$0] } ?? []
    }

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if let album {
                albumContent(album)
            } else if let failure {
                InlineLoadError(failure: failure) { await loadAlbum() }
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
        .onToolbarAction(.showAlbumRemoveConfirmation, addressedTo: albumId) {
            showRemoveConfirmation = true
        }
    }

    private func albumContent(_ album: Album) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Album art and metadata
                VStack(spacing: 16) {
                    Artwork.header(album.images, symbol: "music.note")

                    VStack(spacing: 8) {
                        Text(album.name)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)

                        // The same label either way; only an album that names its artist can
                        // offer the way to them.
                        let artistLabel = Text(album.artistName)
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        if let artistId = album.artistId {
                            Button {
                                navigationCoordinator.navigateToArtistSection(artistId: artistId)
                            } label: {
                                artistLabel
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
                            artistLabel
                        }

                        HStack(spacing: 4) {
                            Text(localizedNumberString("metadata.tracks", album.trackCount))
                            if !tracks.isEmpty {
                                Text("metadata.separator")
                                Text(totalDuration(of: tracks))
                            }
                            if let releaseDate = album.releaseDate {
                                Text("metadata.separator")
                                Text(formatReleaseDate(releaseDate))
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
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
                } else if let failure {
                    InlineLoadError(failure: failure) { await loadAlbum() }
                } else if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tracks.enumerated(), id: \.offset) { index, track in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 54)
                            }

                            TrackRow(
                                track: track,
                                showTrackNumber: true,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                currentSection: .albums,
                                selectionId: albumId,
                                onDoubleTap: {
                                    await playbackViewModel.play(
                                        uriOrUrl: album.uri,
                                        trackIndex: index,
                                        startingAtUri: track.uri,
                                    )
                                },
                            )
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(.horizontal)
                }
            }
        }
    }

    private func loadAlbum() async {
        // Only claim to be loading when the track list is actually missing —
        // a cached album must not flash a spinner over its tracks.
        isLoading = album?.tracksLoaded != true
        failure = nil

        do {
            try await albumService.ensureAlbumLoaded(albumId: albumId)
        } catch {
            // A cancellation is this view going away, not a failure: the load keeps
            // running and its result is in the store for whatever replaces us.
            if !isCancellation(error) {
                failure = LoadFailure(error)
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
            // Use album URI to load via Spirc.load(LoadRequest::from_context_uri())
            // This properly loads the album context instead of individual tracks
            await playbackViewModel.play(uriOrUrl: album.uri)
        }
    }

    private func removeFromLibrary() {
        Task {
            do {
                try await albumService.removeAlbumFromLibrary(albumId: albumId)
                // Navigate away from the removed album
                navigationCoordinator.clearAlbumSelection()
            } catch {
                failure = LoadFailure(message: String(localized: "error.remove_album \(error.localizedDescription)"))
            }
        }
    }
}
