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
    var size = Artwork.cardSize

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToAlbumSection(albumId: id)
        } label: {
            VStack(spacing: 8) {
                Artwork.card(images, size: size, symbol: "music.note")

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: size, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience initializers

extension AlbumCard {
    /// Initialize from an Album entity
    init(album: Album, size: CGFloat = Artwork.cardSize) {
        id = album.id
        name = album.name
        artistName = album.artistName
        images = album.images
        self.size = size
    }
}
