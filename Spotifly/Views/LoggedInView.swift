//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct LoggedInView: View {
    let authResult: SpotifyAuthResult
    let onLogout: () -> Void

    @State private var trackViewModel = TrackLookupViewModel()
    @State private var playbackViewModel = PlaybackViewModel()

    // Helper function for time formatting
    private func formatTime(_ milliseconds: UInt32) -> String {
        let totalSeconds = Int(milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundStyle(.green)

                Text("Spotifly")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button("Logout", role: .destructive) {
                    playbackViewModel.stop()
                    onLogout()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Divider()

            // Spotify URI Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Play Spotify Content")
                    .font(.headline)

                HStack {
                    TextField("Spotify URI or URL (track/album/playlist/artist)", text: $trackViewModel.spotifyURI)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if !trackViewModel.spotifyURI.isEmpty {
                                Task {
                                    await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: authResult.accessToken)
                                }
                            }
                        }

                    Button {
                        trackViewModel.clearInput()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(trackViewModel.spotifyURI.isEmpty)

                    Button("Play") {
                        Task {
                            await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: authResult.accessToken)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(trackViewModel.spotifyURI.isEmpty || playbackViewModel.isLoading)
                }

                if let error = playbackViewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal)

            // Now Playing / Playback Controls
            if playbackViewModel.queueLength > 0 {
                VStack(spacing: 16) {
                    // Current track info with album art
                    HStack(spacing: 16) {
                        // Album art thumbnail
                        if let artURL = playbackViewModel.currentAlbumArtURL,
                           !artURL.isEmpty,
                           let url = URL(string: artURL)
                        {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .empty:
                                    ProgressView()
                                        .frame(width: 60, height: 60)
                                case let .success(image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .cornerRadius(6)
                                case .failure:
                                    Image(systemName: "music.note")
                                        .font(.title2)
                                        .frame(width: 60, height: 60)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(6)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                        } else {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .frame(width: 60, height: 60)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(6)
                        }

                        // Track metadata
                        VStack(alignment: .leading, spacing: 4) {
                            if let trackName = playbackViewModel.currentTrackName {
                                Text(trackName)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                            if let artistName = playbackViewModel.currentArtistName {
                                Text(artistName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            // Queue position
                            Text("\(playbackViewModel.currentIndex + 1) of \(playbackViewModel.queueLength)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // Seek bar
                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { Double(playbackViewModel.currentPositionMs) },
                                set: { newValue in
                                    let positionMs = UInt32(newValue)
                                    do {
                                        try SpotifyPlayer.seek(positionMs: positionMs)
                                        playbackViewModel.currentPositionMs = positionMs

                                        // Update playback start time to maintain sync
                                        if playbackViewModel.isPlaying {
                                            playbackViewModel.playbackStartTime = Date().addingTimeInterval(-Double(positionMs) / 1000.0)
                                        }

                                        playbackViewModel.updateNowPlayingInfo()
                                    } catch {
                                        playbackViewModel.errorMessage = error.localizedDescription
                                    }
                                },
                            ),
                            in: 0 ... Double(max(playbackViewModel.trackDurationMs, 1)),
                        )
                        .tint(.green)

                        // Time labels
                        HStack {
                            Text(formatTime(playbackViewModel.currentPositionMs))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Text(formatTime(playbackViewModel.trackDurationMs))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    // Playback controls
                    HStack(spacing: 20) {
                        Button {
                            playbackViewModel.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!playbackViewModel.hasPrevious)

                        Button {
                            if playbackViewModel.isPlaying {
                                SpotifyPlayer.pause()
                                playbackViewModel.isPlaying = false
                                playbackViewModel.playbackStartTime = nil
                            } else {
                                SpotifyPlayer.resume()
                                playbackViewModel.isPlaying = true
                                // Adjust start time based on current position
                                if playbackViewModel.currentPositionMs > 0 {
                                    playbackViewModel.playbackStartTime = Date().addingTimeInterval(-Double(playbackViewModel.currentPositionMs) / 1000.0)
                                } else {
                                    playbackViewModel.playbackStartTime = Date()
                                }
                            }
                            playbackViewModel.updateNowPlayingInfo()
                        } label: {
                            Image(systemName: playbackViewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button {
                            playbackViewModel.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!playbackViewModel.hasNext)
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            // Track Info Display (optional, only for tracks)
            if trackViewModel.isLoading {
                Spacer()
                ProgressView("Loading track info...")
                Spacer()
            } else if let track = trackViewModel.trackMetadata {
                TrackInfoView(
                    track: track,
                    accessToken: authResult.accessToken,
                    playbackViewModel: playbackViewModel,
                )
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Enter a Spotify URI or URL to start playback")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Supports tracks, albums, playlists, and artists")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding()
        .playbackShortcuts(playbackViewModel: playbackViewModel)
    }
}
