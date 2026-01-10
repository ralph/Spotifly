//
//  AlbumDetailView.swift
//  Spotifly
//
//  Shows details for an album with track list, using normalized store
//

import AppKit
import SwiftUI

struct AlbumDetailView: View {
    // ID is always required (either passed directly or derived from album object)
    let albumId: String

    // Optional pre-loaded album (avoids network request if already have data)
    private let initialAlbum: Album?

    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService

    @State private var album: Album?
    @State private var isLoadingAlbum = false
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                        Text(album.artistName)
                            .font(.title3)
                            .foregroundStyle(.secondary)

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

                    // Play All button and menu
                    HStack(spacing: 12) {
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

                        // Context menu
                        Menu {
                            Button {
                                playNext()
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .disabled(tracks.isEmpty)

                            Button {
                                addToQueue()
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                            .disabled(tracks.isEmpty)

                            Divider()

                            Button {
                                copyToClipboard(album)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .disabled(album.externalUrl == nil)
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
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
                                track: track.toTrackRowData(),
                                showTrackNumber: true,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                playbackViewModel: playbackViewModel,
                                currentSection: .albums,
                                selectionId: albumId,
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
        Task {
            let token = await session.validAccessToken()
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: token,
            )
        }
    }

    private func playNext() {
        Task {
            let token = await session.validAccessToken()
            for track in tracks.reversed() {
                await playbackViewModel.playNext(
                    trackUri: track.uri,
                    accessToken: token,
                )
            }
        }
    }

    private func addToQueue() {
        Task {
            let token = await session.validAccessToken()
            for track in tracks {
                await playbackViewModel.addToQueue(
                    trackUri: track.uri,
                    accessToken: token,
                )
            }
        }
    }

    private func copyToClipboard(_ album: Album) {
        guard let externalUrl = album.externalUrl else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(externalUrl, forType: .string)
    }
}
