//
//  PlaylistCoverImage.swift
//  Spotifly
//
//  An image file made into what a playlist's cover is sent as.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picked image made into a playlist's cover: its centre square, at most `side` pixels a side,
/// as a JPEG.
///
/// The web player sends the file as it was picked, and Spotify shows covers square, at 640 pixels
/// at the most. Cropping here makes the cover the one the user will see, whatever Spotify would
/// make of another shape, and scaling keeps a camera photo's megabytes off a request whose limit
/// nobody has measured.
nonisolated enum PlaylistCoverImage {
    static let side = 640

    /// The cover for an image file picked by the user, made off the main actor while the picker's
    /// grant to it lasts. ImageIO reads only as much of the file as the scaled image needs.
    @concurrent static func jpeg(contentsOf url: URL) async -> Data? {
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(jpeg(from:))
    }

    static func jpeg(from data: Data) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(jpeg(from:))
    }

    /// The cover for an image of any type ImageIO reads, turned as its orientation says; nil for
    /// one that isn't an image.
    private static func jpeg(from source: CGImageSource) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) > 0
        else { return nil }

        // Scaled so its shorter side is `side`, or left as it is when it's smaller than that.
        let longest = Int((Double(side) * Double(max(width, height)) / Double(min(width, height))).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, max(width, height)),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let square = min(scaled.width, scaled.height, side)
        let crop = CGRect(x: (scaled.width - square) / 2, y: (scaled.height - square) / 2, width: square, height: square)
        guard let cover = scaled.cropping(to: crop) else { return nil }

        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cover, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return jpeg as Data
    }
}
