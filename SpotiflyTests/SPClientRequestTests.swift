//
//  SPClientRequestTests.swift
//  SpotiflyTests
//
//  Playback's requests to spclient are signed like the app's pages, and share their retries.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct SPClientRequestTests {
    /// The extended-metadata answer for a track named "Song" with one file.
    private let trackAnswer = SPClientParsingTests.extendedMetadataResponse(track: ProtobufWriter.message {
        $0.string(field: 2, "Song")
        SPClientParsingTests.file(&$0, id: 1, format: 1)
    })

    private let cdnAnswer = Data(#"{"cdnurl":["https://audio.example/file"]}"#.utf8)

    private let contextAnswer = Data(#"""
    {"metadata":{"context_description":"Album"},"pages":[{"tracks":[{"uri":"spotify:track:a","uid":"u1"}]}]}
    """#.utf8)

    /// Answers each request in turn with `statuses`, the last one for every request after it, and
    /// with `body` when the status is a 200. Records the requests it was sent.
    private func spclient(
        _ statuses: [Int],
        body: Data,
        sent: Recorder<URLRequest>,
        pauses: Recorder<Duration> = Recorder(),
        rejected: Recorder<String> = Recorder(),
    ) -> SPClient {
        let credentials = spotifyCredentials(
            invalidateClientToken: { rejected.record($0) },
            pause: { pauses.record($0) },
            transport: { request in
                let status = statuses[min(sent.values.count, statuses.count - 1)]
                sent.record(request)
                return (status == 200 ? body : Data(), httpResponse(status, url: request.url!))
            },
        )
        return SPClient(credentials: credentials, deviceId: "device")
    }

    /// Before, a 503 failed the track's start at once, and said "Track not found".
    @Test func `a track's metadata that meets a server error is asked for again, briefly`() async throws {
        let sent = Recorder<URLRequest>()
        let pauses = Recorder<Duration>()
        let client = spclient([503, 200], body: trackAnswer, sent: sent, pauses: pauses)

        let track = try await client.getTrack(uri: "spotify:track:abc")

        #expect(track.name == "Song")
        #expect(pauses.values == [.milliseconds(250)])
        // The read is a POST, and asked again as one, body and all.
        #expect(sent.values.map(\.httpMethod) == ["POST", "POST"])
        #expect(sent.values.allSatisfy { $0.httpBody == sent.values.first?.httpBody && $0.httpBody != nil })
    }

    @Test func `a server error that goes on is a failed request, not a missing track`() async throws {
        let sent = Recorder<URLRequest>()
        let pauses = Recorder<Duration>()
        let client = spclient([503], body: trackAnswer, sent: sent, pauses: pauses)

        await #expect(throws: LibrespotError.requestFailed("Track metadata", status: 503)) {
            _ = try await client.getTrack(uri: "spotify:track:abc")
        }
        #expect(sent.values.count == 3)
        #expect(pauses.values == [.milliseconds(250), .seconds(1)])
    }

    /// The client token is cached for a fortnight, so a revoked one failed playback until the app
    /// was relaunched.
    @Test func `a refused client token is dropped, and the request asked again`() async throws {
        let sent = Recorder<URLRequest>()
        let rejected = Recorder<String>()
        let client = spclient([401, 200], body: cdnAnswer, sent: sent, rejected: rejected)

        let cdn = try await client.resolveCDNUrl(fileId: Data([0xAB]))

        #expect(cdn.url.absoluteString == "https://audio.example/file")
        #expect(rejected.values == ["ct"])
        #expect(sent.values.count == 2)
    }

    @Test func `a context page that meets a server error is asked for again`() async throws {
        let sent = Recorder<URLRequest>()
        let client = spclient([502, 200], body: contextAnswer, sent: sent)

        let context = try await client.resolveContext("spotify:album:x")

        #expect(context.tracks == ["spotify:track:a"])
        #expect(sent.values.count == 2)
    }

    /// The same headers the pages send: no public API answers these, only the desktop client's
    /// shape.
    @Test func `each request is signed like the desktop client`() async throws {
        let sent = Recorder<URLRequest>()
        let client = spclient([200], body: cdnAnswer, sent: sent)

        _ = try await client.resolveCDNUrl(fileId: Data([0xAB]))

        let request = try #require(sent.values.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        #expect(request.value(forHTTPHeaderField: "Client-Token") == "ct")
        #expect(request.value(forHTTPHeaderField: "App-Platform") == "OSX_ARM64")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    /// The dealer's state report: a report asked again later could land after the newer one that
    /// replaced it.
    @Test func `a write is asked again after a 401, and not after a server error`() async throws {
        for (statuses, expected) in [([401, 200], 2), ([503, 200], 1)] {
            let sent = Recorder<URLRequest>()
            let credentials = spotifyCredentials(invalidateClientToken: { _ in }, transport: { request in
                let status = statuses[min(sent.values.count, statuses.count - 1)]
                sent.record(request)
                return (Data(), httpResponse(status, url: request.url!))
            })

            _ = try await credentials.send(URLRequest(url: #require(URL(string: "https://spclient.example/connect-state"))))

            #expect(sent.values.count == expected, "\(statuses)")
        }
    }
}
