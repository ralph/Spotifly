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

    var body: some View {
        ScrollView {
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
            .padding()
        }
        .navigationTitle("section.tracks")
    }
}
