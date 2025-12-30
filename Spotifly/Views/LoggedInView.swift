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

            // Playback Controls
            if playbackViewModel.queueLength > 0 {
                VStack(spacing: 12) {
                    // Queue info
                    HStack {
                        Text("Queue:")
                            .font(.headline)
                        Text("\(playbackViewModel.currentIndex + 1) of \(playbackViewModel.queueLength)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let trackName = playbackViewModel.getQueueTrackName(at: playbackViewModel.currentIndex) {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(trackName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Navigation buttons
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
                            } else {
                                SpotifyPlayer.resume()
                                playbackViewModel.isPlaying = true
                            }
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
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
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
    }
}
