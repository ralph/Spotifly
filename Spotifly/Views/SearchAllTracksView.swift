//
//  SearchAllTracksView.swift
//  Spotifly
//
//  Displays all tracks from search results in a scrollable list
//

import SwiftUI

struct SearchAllTracksView: View {
    let tracks: [Track]
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session

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
                // Header with play button
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, height: 120)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)

                    VStack(spacing: 8) {
                        Text("section.tracks")
                            .font(.title2)
                            .fontWeight(.semibold)

                        HStack(spacing: 4) {
                            Text(String(format: String(localized: "metadata.tracks"), tracks.count))
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text("metadata.separator")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text(totalDuration)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }

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
                    .disabled(tracks.isEmpty)
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
        .navigationTitle("section.tracks")
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
