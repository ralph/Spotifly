//
//  AlbumDetailView.swift
//  Spotifly
//
//  Shows details for an album search result with track list
//

import SwiftUI

struct AlbumDetailView: View {
    let album: SearchAlbum
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    @State private var tracks: [AlbumTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

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

                        Text("\(album.totalTracks) tracks • \(album.releaseDate)")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }

                    // Play All button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("Play Album", systemImage: "play.fill")
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
                        ForEach(tracks) { track in
                            HStack(spacing: 12) {
                                Text("\(track.trackNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.name)
                                        .font(.subheadline)
                                    Text(track.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
        .task {
            await loadTracks()
        }
    }

    private func loadTracks() async {
        guard tracks.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            tracks = try await SpotifyAPI.fetchAlbumTracks(
                accessToken: authResult.accessToken,
                albumId: album.id
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
