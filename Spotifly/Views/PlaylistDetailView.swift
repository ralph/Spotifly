//
//  PlaylistDetailView.swift
//  Spotifly
//
//  Shows details for a playlist search result with track list
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: SearchPlaylist
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                        Text("By \(playlist.ownerName) • \(playlist.trackCount) tracks")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // Play All button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("Play Playlist", systemImage: "play.fill")
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
                    ProgressView("Loading tracks...")
                        .padding()
                } else if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                } else if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)

                                if let imageURL = track.imageURL {
                                    AsyncImage(url: imageURL) { phase in
                                        switch phase {
                                        case .empty:
                                            ProgressView()
                                                .frame(width: 40, height: 40)
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 40, height: 40)
                                                .cornerRadius(4)
                                        case .failure:
                                            Image(systemName: "music.note")
                                                .frame(width: 40, height: 40)
                                                .background(Color.gray.opacity(0.2))
                                                .cornerRadius(4)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(width: 40, height: 40)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(4)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.name)
                                        .font(.subheadline)
                                    Text("\(track.artistName) • \(track.albumName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(formatDuration(track.durationMs))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                Task {
                                    await playbackViewModel.play(
                                        uriOrUrl: track.uri,
                                        accessToken: authResult.accessToken
                                    )
                                }
                            }

                            if track.id != tracks.last?.id {
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
        .task {
            await loadTracks()
        }
    }

    private func loadTracks() async {
        guard tracks.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            tracks = try await SpotifyAPI.fetchPlaylistTracks(
                accessToken: authResult.accessToken,
                playlistId: playlist.id
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
                accessToken: authResult.accessToken
            )
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
