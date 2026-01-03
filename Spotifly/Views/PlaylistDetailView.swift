//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist search result with track list
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: SearchPlaylist
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session

    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                // Playlist art and metadata
                VStack(spacing: 16) {
                    if let imageURL = playlist.imageURL {
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
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 60))
                                    .frame(width: 200, height: 200)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .frame(width: 200, height: 200)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                    }

                    VStack(spacing: 8) {
                        Text(playlist.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)

                        if let description = playlist.description, !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }

                        HStack(spacing: 4) {
                            Text(String(format: String(localized: "metadata.by_owner"), playlist.ownerName))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text("metadata.separator")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text(String(format: String(localized: "metadata.tracks"), playlist.trackCount))
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
                        }
                    }

                    // Play All button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("playback.play_playlist", systemImage: "play.fill")
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
                                track: track.toTrackRowData(),
                                index: index,
                                currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                                playbackViewModel: playbackViewModel,
                                accessToken: session.accessToken,
                            )

                            if index < tracks.count - 1 {
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
        }
        .task(id: playlist.id) {
            await loadTracks()
        }
    }

    private func loadTracks() async {
        // Clear old tracks when loading new playlist
        tracks = []
        isLoading = true
        errorMessage = nil

        do {
            tracks = try await SpotifyAPI.fetchPlaylistTracks(
                accessToken: session.accessToken,
                playlistId: playlist.id,
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func playAllTracks() {
        Task {
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: session.accessToken,
            )
        }
    }
}
