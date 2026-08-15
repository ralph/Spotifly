//
//  TrackCard.swift
//  Spotifly
//
//  Reusable track card for horizontal scroll sections
//

import SwiftUI

struct TrackCard: View {
    let track: Track
    let playbackViewModel: PlaybackViewModel
    var currentSection: NavigationItem = .searchResults

    @Environment(TrackService.self) private var trackService

    var body: some View {
        Button {
            Task {
                await playbackViewModel.playRadio(trackUri: track.uri)
            }
        } label: {
            VStack(spacing: 8) {
                CardArtwork(images: track.images, outline: .roundedSquare, symbol: "music.note", symbolSize: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: CardArtwork.size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackContextMenu(
                track: track,
                currentSection: currentSection,
                selectionId: nil,
                playbackViewModel: playbackViewModel,
            )
        }
        .task(id: track.id) {
            await trackService.ensureFavoriteStatuses(trackIds: [track.id])
        }
    }
}
