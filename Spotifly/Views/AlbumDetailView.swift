//
//  AlbumDetailView.swift
//  Spotifly
//
//  Shows details for an album with track list, using normalized store
//

import AppKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct AlbumDetailView: View {
    let album: SearchAlbum
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(AlbumService.self) private var albumService

    @State private var isLoading = false
    @State private var errorMessage: String?

    /// Tracks from the store for this album
    private var tracks: [Track] {
        guard let storedAlbum = store.albums[album.id] else { return [] }
        return storedAlbum.trackIds.compactMap { store.tracks[$0] }
    }

    private var totalDuration: String {
        let totalMs = tracks.reduce(0) { $0 + $1.durationMs }
        let totalSeconds = totalMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
    }

    var body: some View {
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
                            Text(String(format: String(localized: "metadata.tracks"), album.totalTracks))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            if !tracks.isEmpty {
                                Text("metadata.separator")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                Text(totalDuration)
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                            }
                            Text("metadata.separator")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text(album.releaseDate)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
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
                                copyToClipboard()
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
                            )

                            if index < tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
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
        }
        .task(id: album.id) {
            await loadTracks()
        }
    }

    private func loadTracks() async {
        isLoading = true
        errorMessage = nil

        do {
            let token = await session.validAccessToken()
            // Load tracks via service (stores them in AppStore)
            _ = try await albumService.getAlbumTracks(
                albumId: album.id,
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

    private func copyToClipboard() {
        guard let externalUrl = album.externalUrl else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(externalUrl, forType: .string)
    }
}
