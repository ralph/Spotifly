//
//  AlbumCard.swift
//  Spotifly
//
//  Reusable album card for horizontal scroll sections
//

import SwiftUI

struct AlbumCard: View {
    let id: String
    let name: String
    let artistName: String
    let images: ImageSet

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToAlbumSection(albumId: id)
        } label: {
            VStack(spacing: 8) {
                CardArtwork(images: images, outline: .roundedSquare, symbol: "music.note", symbolSize: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                    Text(artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: CardArtwork.size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience initializers

extension AlbumCard {
    /// Initialize from an Album entity
    init(album: Album) {
        id = album.id
        name = album.name
        artistName = album.artistName
        images = album.images
    }
}
