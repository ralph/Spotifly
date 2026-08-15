//
//  ArtistCard.swift
//  Spotifly
//
//  Reusable circular artist card for horizontal scroll sections
//

import SwiftUI

struct ArtistCard: View {
    let id: String
    let name: String
    let images: ImageSet

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            navigationCoordinator.navigateToArtistSection(artistId: id)
        } label: {
            VStack(spacing: 8) {
                CardArtwork(images: images, outline: .circle, symbol: "person.circle.fill", symbolSize: 60)

                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: CardArtwork.size)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Convenience initializers

extension ArtistCard {
    /// Initialize from an Artist entity
    init(artist: Artist) {
        id = artist.id
        name = artist.name
        images = artist.images
    }
}
