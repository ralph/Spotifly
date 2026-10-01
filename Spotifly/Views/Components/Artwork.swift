//
//  Artwork.swift
//  Spotifly
//
//  The square artwork of an album, artist, playlist or track
//

import SwiftUI

/// A square artwork: a spinner while it loads, the image clipped to its shape, and a glyph
/// placeholder when there is no artwork, it fails to load, or the network is away.
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
    /// Shows the placeholder instead of a spinner while the image loads, as the library lists do.
    var placeholderWhileLoading = false

    @Environment(\.displayScale) private var displayScale

    private let network = NetworkMonitor.shared

    var body: some View {
        if let url = images.url(for: size, scale: displayScale) {
            RetryingAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    // Offline, the request waits for a connection that is gone, and nothing loads
                    // until it returns, when `RetryingAsyncImage` asks again.
                    if placeholderWhileLoading || !network.isOnline {
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
        symbolSize: CGFloat = 40,
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

    /// The artwork at the top of an album's, an artist's or a playlist's page.
    static func header(
        _ images: ImageSet,
        shape: AnyShape = AnyShape(.rect(cornerRadius: 8)),
        symbol: String,
        symbolSize: CGFloat = 60,
    ) -> Artwork {
        Artwork(
            images: images,
            size: 200,
            shape: shape,
            symbol: symbol,
            symbolFont: .system(size: symbolSize),
            shadowRadius: 10,
        )
    }
}
