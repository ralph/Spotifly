//
//  PlaylistCoverTests.swift
//  SpotiflyTests
//
//  Setting a playlist's cover: the image made of a picked file, and the requests it goes in.
//

import Foundation
import ImageIO
@testable import Spotifly
import Testing
import UniformTypeIdentifiers

/// The three requests the web player made to set a cover, on 2026-10-02.
struct PlaylistCoverRequestTests {
    private func api(_ sent: Recorder<URLRequest>, uploadStatus: Int = 200) -> SpclientAPI {
        spclientAPI(transport: { request in
            sent.record(request)
            let path = request.url?.path ?? ""
            let (status, body) = if path == "/v4/playlist" {
                (uploadStatus, #"{"uploadToken":"token-1"}"#)
            } else if path.hasSuffix("/register-image") {
                (200, #"{"picture":"q83vEjRWeJCrze8SNFZ4kKvN7xI="}"#)
            } else {
                (200, #"{"revision":"r"}"#)
            }
            return (Data(body.utf8), httpResponse(status, url: request.url!))
        })
    }

    @Test func `the image goes up, is registered, and becomes the playlist's picture`() async throws {
        let sent = Recorder<URLRequest>()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

        try await api(sent).changePlaylistCover(id: "p1", jpeg: jpeg)

        let requests = sent.values
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST"])
        #expect(requests.map { $0.url?.host } == ["image-upload.spotify.com", "spclient.wg.spotify.com", "spclient.wg.spotify.com"])
        #expect(requests.map { $0.url?.path } == ["/v4/playlist", "/playlist/v2/playlist/p1/register-image", "/playlist/v2/playlist/p1/changes"])

        let upload = try #require(requests.first)
        #expect(upload.httpBody == jpeg)
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(upload.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(upload.value(forHTTPHeaderField: "Client-Token") != nil)

        try expectMatch(requests[1].httpBody, #"{"uploadToken":"token-1"}"#)
        try expectMatch(requests[2].httpBody, PlaylistChangeBodyTests.webClientCover)
    }

    @Test func `an upload that fails registers nothing`() async throws {
        let sent = Recorder<URLRequest>()

        await #expect(throws: SpclientError.self) {
            try await api(sent, uploadStatus: 413).changePlaylistCover(id: "p1", jpeg: Data([0xFF]))
        }
        #expect(sent.values.count == 1)
    }

    @Test @MainActor func `a file that isn't an image fails before anything is sent`() async throws {
        let sent = Recorder<URLRequest>()
        let service = PlaylistService(store: AppStore(), spclientAPI: api(sent))
        let file = FileManager.default.temporaryDirectory.appending(path: "not-an-image-\(UUID().uuidString).txt")
        try Data("not an image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await #expect(throws: PlaylistCoverError.self) {
            try await service.changePlaylistCover(playlistId: "p1", imageAt: file)
        }
        #expect(sent.values.isEmpty)
    }

    /// The change answers nothing about the image, so the playlist's cover is read again, from a
    /// one-item page, and only its images are written.
    @Test @MainActor func `after a change only the cover is read again`() async throws {
        let store = AppStore()
        store.upsertPlaylist(playlist(id: "p1"))
        let pages = Recorder<URLRequest>()
        let reread = #"{"data":{"playlistV2":{"__typename":"Playlist","uri":"spotify:playlist:p1","name":"Playlist","#
            + #""images":{"items":[{"sources":[{"url":"https://image-cdn-fa.spotifycdn.com/image/new","width":640,"height":640}]}]},"#
            + #""content":{"totalCount":0,"items":[]}}}}"#
        let service = PlaylistService(
            store: store,
            partnerAPI: partnerAPI { request in
                pages.record(request)
                return (Data(reread.utf8), httpResponse(200))
            },
            spclientAPI: api(Recorder<URLRequest>()),
        )

        try await service.removePlaylistCover(playlistId: "p1")

        let variables = try #require(pages.values.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["variables"] as? [String: Any])
        #expect(pages.values.count == 1)
        #expect(variables["limit"] as? Int == 1)
        #expect(store.playlists["p1"]?.images.variants.map(\.url.absoluteString) == ["https://image-cdn-fa.spotifycdn.com/image/new"])
        #expect(store.playlists["p1"]?.name == "Playlist")
    }
}

/// A picked image made into a cover: its centre square, at most 640 pixels a side, as a JPEG.
struct PlaylistCoverImageTests {
    /// A PNG `width` by `height`, its left third red, its middle green, its right third blue, or
    /// the same top to bottom when it's taller than wide.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        let colors: [CGColor] = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)]
        for (third, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(width >= height
                ? CGRect(x: width * third / 3, y: 0, width: width / 3 + 1, height: height)
                : CGRect(x: 0, y: height * third / 3, width: width, height: height / 3 + 1))
        }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func image(_ data: Data) throws -> (type: String?, image: CGImage) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try (CGImageSourceGetType(source) as String?, #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// The colour at a point, as its strongest channel: 0 red, 1 green, 2 blue.
    private func channel(of image: CGImage, x: Int, y: Int) throws -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return try #require(pixel.prefix(3).indices.max { pixel[$0] < pixel[$1] })
    }

    @Test func `a wide photo becomes its centre square, at 640 pixels`() throws {
        let cover = try image(#require(PlaylistCoverImage.jpeg(from: png(width: 3000, height: 1000))))

        #expect(cover.type == UTType.jpeg.identifier)
        #expect(cover.image.width == 640)
        #expect(cover.image.height == 640)
        // The middle third, green, fills it from edge to edge.
        #expect(try channel(of: cover.image, x: 5, y: 320) == 1)
        #expect(try channel(of: cover.image, x: 634, y: 320) == 1)
    }

    @Test func `a tall one is cut to its middle too`() throws {
        let cover = try image(#require(PlaylistCoverImage.jpeg(from: png(width: 900, height: 2700))))

        #expect(cover.image.width == 640)
        #expect(cover.image.height == 640)
        #expect(try channel(of: cover.image, x: 320, y: 5) == 1)
        #expect(try channel(of: cover.image, x: 320, y: 634) == 1)
    }

    @Test func `a small image is cut square, not scaled up`() throws {
        let cover = try image(#require(PlaylistCoverImage.jpeg(from: png(width: 300, height: 200))))

        #expect(cover.image.width == 200)
        #expect(cover.image.height == 200)
    }

    @Test func `data that isn't an image makes no cover`() {
        #expect(PlaylistCoverImage.jpeg(from: Data("not an image".utf8)) == nil)
    }
}
