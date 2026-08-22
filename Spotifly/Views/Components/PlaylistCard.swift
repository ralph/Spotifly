//
//  PlaylistCard.swift
//  Spotifly
//
//  Reusable playlist card for horizontal scroll sections
//

import SwiftUI

struct PlaylistCard: View {
    let id: String
    let name: String
    let images: ImageSet

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToPlaylistSection(playlistId: id)
        } label: {
            VStack(spacing: 8) {
                CardArtwork(images: images, outline: .roundedSquare, symbol: "music.note.list", symbolSize: 40)

                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .frame(width: CardArtwork.size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience initializers

extension PlaylistCard {
    /// Initialize from a Playlist entity
    init(playlist: Playlist) {
        id = playlist.id
        name = playlist.name
        images = playlist.images
    }
}
