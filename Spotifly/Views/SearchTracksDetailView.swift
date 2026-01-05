//
//  SearchTracksDetailView.swift
//  Spotifly
//
//  Shows all tracks from search results
//

import SwiftUI

struct SearchTracksDetailView: View {
    let tracks: [SearchTrack]
    @Bindable var playbackViewModel: PlaybackViewModel
    @Environment(SpotifySession.self) private var session
    @Environment(TrackService.self) private var trackService

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)

                        Text("section.all_tracks")
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
                            accessToken: session.accessToken,
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
        .task(id: tracks.map(\.id)) {
            // Check favorite status and update store
            let trackIds = tracks.map(\.id)
            try? await trackService.checkFavoriteStatus(trackIds: trackIds, accessToken: session.accessToken)
        }
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
