//
//  RecentTracksDetailView.swift
//  Spotifly
//
//  Shows all recently played tracks
//

import SwiftUI

struct RecentTracksDetailView: View {
    let tracks: [Track]
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)

                        Text("recently_played.tracks")
                            .font(.title)
                            .fontWeight(.bold)

                        Text(String(format: String(localized: "metadata.tracks"), tracks.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Play all button
                    Button {
                        playAllTracks()
                    } label: {
                        Label("playback.play_tracks", systemImage: "play.fill")
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
                            playbackViewModel: playbackViewModel,
                            currentSection: .startpage,
                        )

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
            let token = await session.validAccessToken()
            await playbackViewModel.playTracks(
                tracks.map(\.uri),
                accessToken: token,
            )
        }
    }
}
