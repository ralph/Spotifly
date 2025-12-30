//
//  StartpageView.swift
//  Spotifly
//
//  Startpage with playback controls and track lookup
//

import SwiftUI

struct StartpageView: View {
    let authResult: SpotifyAuthResult
    @Bindable var trackViewModel: TrackLookupViewModel
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(spacing: 20) {
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
