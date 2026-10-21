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
    /// Under the name: its track count for the listener's own, its owner for anyone else's.
    var subtitle: String?
    var size = Artwork.cardSize

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToPlaylistSection(playlistId: id)
        } label: {
            VStack(spacing: 8) {
                Artwork.card(images, size: size, symbol: "music.note.list")

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience initializers

extension PlaylistCard {
    /// Initialize from a Playlist entity
    init(playlist: Playlist, subtitle: String? = nil, size: CGFloat = Artwork.cardSize) {
        id = playlist.id
        name = playlist.name
        images = playlist.images
        self.subtitle = subtitle
        self.size = size
    }
}
