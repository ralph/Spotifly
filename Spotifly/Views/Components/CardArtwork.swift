//
//  CardArtwork.swift
//  Spotifly
//
//  Shared artwork for the cards in horizontal scroll sections
//

import SwiftUI

/// The image at the top of an album, artist, playlist or track card: a spinner while it
/// loads, and a glyph placeholder when there is no artwork or it fails to load.
///
/// All four cards drew this themselves, byte for byte, differing only in the outline and
/// the placeholder glyph.
struct CardArtwork: View {
    /// What the artwork is clipped to, and what shape the placeholder is filled with —
    /// a circle for artists, a rounded square for everything else.
    enum Outline {
        case roundedSquare
        case circle
    }

    let images: ImageSet
    let outline: Outline
    /// Glyph shown when there is no artwork to show.
    let symbol: String
    let symbolSize: CGFloat

    /// The artwork is square, and a card's caption is laid out to the same width.
    static let size: CGFloat = 120

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let url = images.url(for: Self.size, scale: displayScale) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: Self.size, height: Self.size)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.size, height: Self.size)
                        .clipShape(shape)
                        .shadow(radius: 2)
                case .failure:
                    placeholder
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            placeholder
        }
    }

    private var shape: AnyShape {
        switch outline {
        case .roundedSquare: AnyShape(.rect(cornerRadius: 4))
        case .circle: AnyShape(.circle)
        }
    }

    private var placeholder: some View {
        shape
            .fill(.quaternary)
            .frame(width: Self.size, height: Self.size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(.secondary),
            )
    }
}
