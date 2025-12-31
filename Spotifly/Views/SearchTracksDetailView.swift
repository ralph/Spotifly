//
//  SearchTracksDetailView.swift
//  Spotifly
//
//  Shows all tracks from search results
//

import SwiftUI

struct SearchTracksDetailView: View {
    let tracks: [SearchTrack]
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)

                        Text("All Tracks")
                            .font(.title)
                            .fontWeight(.bold)

                        Text("\(tracks.count) tracks")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Play all button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("Play Tracks", systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(.top, 24)

                // Track list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track.toTrackRowData(),
                            index: index,
                            currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                            playbackViewModel: playbackViewModel
                        ) {
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

    private func playAllTracks() {
        Task {
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: authResult.accessToken
            )
        }
    }
}
