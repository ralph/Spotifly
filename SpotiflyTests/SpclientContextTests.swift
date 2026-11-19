//
//  SpclientContextTests.swift
//  SpotiflyTests
//
//  The context resolver's requests to spclient are signed like the app's pages, and share
//  their retries.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct SpclientContextTests {
    private let contextAnswer = Data(#"""
    {"metadata":{"context_description":"Album"},"pages":[{"tracks":[{"uri":"spotify:track:a","uid":"u1"}]}]}
    """#.utf8)

    /// How Spotify refuses a client token it will not take, measured 2026-10-01.
    private static let refusal = (status: 400, headers: ["client-token-error": "INVALID_CLIENTTOKEN"])

    /// Answers each request in turn with `statuses`, the last one for every request after it, and
    /// with `body` when the status is a 200, `failureHeaders` when it is not. Records the requests
    /// it was sent.
    private func scripted(
        _ statuses: [Int],
        body: Data = Data(),
        failureHeaders: [String: String]? = nil,
        sent: Recorder<URLRequest>,
    ) -> SpotifyCredentials.Transport {
        { request in
            // Read before the request is recorded, so the first request gets the first status.
            let status = statuses[min(sent.values.count, statuses.count - 1)]
            sent.record(request)
            let headers = status == 200 ? nil : failureHeaders
            return (status == 200 ? body : Data(), httpResponse(status, url: request.url!, headers: headers))
        }
    }

    private func spclient(
        _ statuses: [Int],
        body: Data,
        failureHeaders: [String: String]? = nil,
        sent: Recorder<URLRequest>,
        pauses: Recorder<Duration> = Recorder(),
        rejected: Recorder<String> = Recorder(),
    ) -> SpclientAPI {
        let credentials = spotifyCredentials(
            invalidateClientToken: { rejected.record($0) },
            pause: { pauses.record($0) },
            transport: scripted(statuses, body: body, failureHeaders: failureHeaders, sent: sent),
        )
        return SpclientAPI(credentials: credentials)
    }

    /// The status a resolve failed with, if it failed as a refused request.
    private func refusal(of client: SpclientAPI, resolving uri: String = "spotify:album:x") async -> Int? {
        do {
            _ = try await client.resolveContext(uri, deviceId: "device")
            return nil
        } catch let SpclientError.requestFailed(status, _) {
            return status
        } catch {
            return nil
        }
    }

    @Test func `a server error that goes on is a failed request`() async {
        let sent = Recorder<URLRequest>()
        let pauses = Recorder<Duration>()
        let client = spclient([503], body: contextAnswer, sent: sent, pauses: pauses)

        #expect(await refusal(of: client) == 503)
        #expect(sent.values.count == 3)
        #expect(pauses.values == [.seconds(1), .seconds(3)])
    }

    /// The client token is cached for a fortnight, so a revoked one failed every request until
    /// the app was relaunched. Spotify refuses one with a 401, or with a header naming it.
    @Test func `a refused client token is dropped, and the request asked again`() async throws {
        for (status, headers) in [(401, nil), (Self.refusal.status, Self.refusal.headers)] {
            let sent = Recorder<URLRequest>()
            let rejected = Recorder<String>()
            let client = spclient([status, 200], body: contextAnswer, failureHeaders: headers, sent: sent, rejected: rejected)

            let context = try await client.resolveContext("spotify:album:x", deviceId: "device")

            #expect(context.tracks == ["spotify:track:a"])
            #expect(rejected.values == ["ct"], "\(status)")
            #expect(sent.values.count == 2, "\(status)")
        }
    }

    /// A 400 is also a bad request, which asking again would not mend.
    @Test func `a 400 that does not name the client token is not asked again`() async {
        let sent = Recorder<URLRequest>()
        let rejected = Recorder<String>()
        let client = spclient([400, 200], body: contextAnswer, sent: sent, rejected: rejected)

        #expect(await refusal(of: client) == 400)
        #expect(rejected.values.isEmpty)
        #expect(sent.values.count == 1)
    }

    /// A station's next page was named as an `hm://` url, which the resolver answered 404, failing
    /// the whole resolve (2026-10-02).
    @Test func `a context's next page at an hm url is asked of spclient at its path`() async throws {
        let sent = Recorder<URLRequest>()
        let first = Data(#"{"pages":[{"tracks":[{"uri":"spotify:track:a","uid":"u1"}],"next_page_url":"hm://some-service/v1/page?count=1"}]}"#.utf8)
        let next = Data(#"{"tracks":[{"uri":"spotify:track:b","uid":"u2"}]}"#.utf8)
        let credentials = spotifyCredentials(transport: { request in
            sent.record(request)
            return (sent.values.count == 1 ? first : next, httpResponse(200, url: request.url!))
        })
        let client = SpclientAPI(credentials: credentials)

        let context = try await client.resolveContext("spotify:playlist:x", deviceId: "device")

        #expect(context.tracks == ["spotify:track:a", "spotify:track:b"])
        #expect(context.nextPageUrl == nil)
        #expect(sent.values.last?.url?.path == "/some-service/v1/page")
        #expect(sent.values.last?.url?.query == "count=1")
        #expect(SpclientAPI.nextPagePath("spotify:album:x?page=2") == "/context-resolve/v1/spotify:album:x?page=2")
    }

    /// A station is queued from its first page: it names pages without end. From its third page
    /// on, its pages are named at `radio-router`, which spclient answers 404, and asked at
    /// `radio-apollo`, which answers them (2026-10-02).
    @Test func `a station is resolved a page at a time, its next page asked of the radio service`() async throws {
        let sent = Recorder<URLRequest>()
        let first = Data(#"{"pages":[{"tracks":[{"uri":"spotify:track:a"}],"next_page_url":"hm://radio-router/v3/tracks/spotify:station:track:x?count=50&prev_tracks=a"}]}"#.utf8)
        let credentials = spotifyCredentials(transport: { request in
            sent.record(request)
            return (first, httpResponse(200, url: request.url!))
        })
        let client = SpclientAPI(credentials: credentials)
        #expect(SpclientAPI.pagesUpFront(of: "spotify:station:track:x") == 1)
        #expect(SpclientAPI.pagesUpFront(of: "spotify:playlist:x") == 10)

        let station = try await client.resolveContext("spotify:station:track:x", deviceId: "device", pageLimit: 1)
        #expect(station.tracks == ["spotify:track:a"])
        #expect(sent.values.count == 1)

        let next = try SpclientAPI.nextPagePath(#require(station.nextPageUrl))
        #expect(next == "/radio-apollo/v3/tracks/spotify:station:track:x?count=50&prev_tracks=a")
    }

    /// The latest page's tracks come first in `prev_tracks`, and the url was refused with 431 at
    /// 500 of them (2026-10-02), so the oldest are left out.
    @Test func `a station page names only the tracks played last`() {
        let played = (0 ..< 400).map { "t\($0)" }
        let url = "hm://radio-router/v3/tracks/spotify:station:track:x?salt=1&prev_tracks=\(played.joined(separator: ","))&count=50"
        let path = SpclientAPI.nextPagePath(url)
        let named = path.components(separatedBy: "prev_tracks=")[1].components(separatedBy: "&")[0].split(separator: ",")

        #expect(named.count == SpclientAPI.stationPageMemory)
        #expect(named.first == "t0")
        #expect(named.last == "t\(SpclientAPI.stationPageMemory - 1)")
        #expect(path.hasPrefix("/radio-apollo/v3/tracks/spotify:station:track:x?salt=1&prev_tracks=t0,"))
        #expect(path.hasSuffix("&count=50"))

        let short = "hm://radio-apollo/v3/tracks/spotify:station:track:x?prev_tracks=a,b"
        #expect(SpclientAPI.nextPagePath(short) == "/radio-apollo/v3/tracks/spotify:station:track:x?prev_tracks=a,b")
    }

    /// A track queues as itself, a link as its uri, and neither asks the resolver.
    @Test func `a track is queued without resolving anything`() async throws {
        let sent = Recorder<URLRequest>()
        let client = spclient([200], body: contextAnswer, sent: sent)

        #expect(try await client.queueableTracks(for: "spotify:track:t1", deviceId: "device") == ["spotify:track:t1"])
        #expect(try await client.queueableTracks(for: " https://open.spotify.com/track/t1?si=abc", deviceId: "device") == ["spotify:track:t1"])
        #expect(sent.values.isEmpty)
        #expect(try await client.queueableTracks(for: "spotify:album:x", deviceId: "device") == ["spotify:track:a"])
    }

    @Test func `a later page that fails leaves the pages before it`() async throws {
        let first = Data(#"{"pages":[{"tracks":[{"uri":"spotify:track:a"}],"next_page_url":"hm://some-service/v1/page"}]}"#.utf8)
        let client = spclient([200, 404], body: first, sent: Recorder())

        let context = try await client.resolveContext("spotify:playlist:x", deviceId: "device")
        #expect(context.tracks == ["spotify:track:a"])
        #expect(context.nextPageUrl == nil)

        // The first page failing is the resolve failing.
        let refused = spclient([404], body: Data(), sent: Recorder())
        #expect(await refusal(of: refused) == 404)
    }

    @Test func `a context page that meets a server error is asked for again`() async throws {
        let sent = Recorder<URLRequest>()
        let client = spclient([502, 200], body: contextAnswer, sent: sent)

        let context = try await client.resolveContext("spotify:album:x", deviceId: "device")

        #expect(context.tracks == ["spotify:track:a"])
        #expect(sent.values.count == 2)
    }

    /// The same headers the pages send: no public API answers these, only the desktop client's
    /// shape.
    @Test func `each request is signed like the desktop client`() async throws {
        let sent = Recorder<URLRequest>()
        let client = spclient([200], body: contextAnswer, sent: sent)

        _ = try await client.resolveContext("spotify:album:x", deviceId: "device")

        let request = try #require(sent.values.first)
        #expect(request.url?.absoluteString == "https://spclient.wg.spotify.com/context-resolve/v1/spotify%3Aalbum%3Ax?device_id=device")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        #expect(request.value(forHTTPHeaderField: "Client-Token") == "ct")
        #expect(request.value(forHTTPHeaderField: "App-Platform") == "OSX_ARM64")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/x-protobuf")
    }

    /// The dealer's state report: a report asked again later could land after the newer one that
    /// replaced it.
    @Test func `a write is asked again after a refused client token, and not after a server error`() async throws {
        let cases: [(statuses: [Int], headers: [String: String]?, expected: Int)] = [
            ([401, 200], nil, 2),
            ([Self.refusal.status, 200], Self.refusal.headers, 2),
            ([503, 200], nil, 1),
        ]
        for (statuses, headers, expected) in cases {
            let sent = Recorder<URLRequest>()
            let credentials = spotifyCredentials(invalidateClientToken: { _ in }, transport: scripted(statuses, failureHeaders: headers, sent: sent))

            _ = try await credentials.send(URLRequest(url: #require(URL(string: "https://spclient.example/connect-state"))))

            #expect(sent.values.count == expected, "\(statuses)")
        }
    }
}
