//
//  Artwork.swift
//  Spotifly
//
//  The square artwork of an album, artist, playlist or track
//

import SwiftUI

/// A square artwork: a spinner while it loads, the image clipped to its shape, and a glyph
/// placeholder when there is no artwork or it fails to load.
///
/// The cards, the album and playlist headers, an artist's discography, the track rows and the
/// library lists each wrote this out themselves, differing only in what they pass here. What
/// does not fit keeps its own switch around `RetryingAsyncImage`: an artist's own image, whose
/// placeholder is a person, the now-playing bar, which keeps the last image through a change of
/// track, and the profile's avatar, which falls back to initials.
struct Artwork: View {
    let images: ImageSet
    /// The side of the square, in points; it also picks the image variant to load.
    let size: CGFloat
    /// What the image is clipped to, and what shape the placeholder is filled with.
    let shape: AnyShape
    /// Glyph shown when there is no artwork to show.
    let symbol: String
    let symbolFont: Font
    /// A shadow under the loaded image; the placeholder has none.
    var shadowRadius: CGFloat?
    /// Shows the placeholder instead of a spinner while the image loads, for a list's rows,
    /// where a spinner in every row would be noise.
    var placeholderWhileLoading = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let url = images.url(for: size, scale: displayScale) {
            RetryingAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    if placeholderWhileLoading {
                        placeholder
                    } else {
                        ProgressView()
                            .frame(width: size, height: size)
                    }
                case let .success(image):
                    let artwork = image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(shape)
                    if let shadowRadius {
                        artwork.shadow(radius: shadowRadius)
                    } else {
                        artwork
                    }
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

    private var placeholder: some View {
        shape
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(symbolFont)
                    .foregroundStyle(.secondary),
            )
    }
}

extension Artwork {
    /// The side of a card's artwork. A card's caption is laid out to the same width.
    static let cardSize: CGFloat = 120

    /// The artwork at the top of an album, artist, playlist or track card: a rounded square, and
    /// a circle for an artist.
    static func card(
        _ images: ImageSet,
        shape: AnyShape = AnyShape(.rect(cornerRadius: 4)),
        symbol: String,
        symbolSize: CGFloat,
    ) -> Artwork {
        Artwork(
            images: images,
            size: cardSize,
            shape: shape,
            symbol: symbol,
            symbolFont: .system(size: symbolSize),
            shadowRadius: 2,
        )
    }
}
