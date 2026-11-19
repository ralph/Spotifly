//
//  SPClient.swift
//  SwiftLibrespot
//
//  HTTP client for Spotify spclient's context resolver
//

import Foundation

/// HTTP client for Spotify spclient's context resolver, which says what tracks an album or a
/// playlist queues as (`LibrespotClient.queueableTracks`).
public actor SPClient {
    // MARK: - Properties

    /// Signs each request like the desktop client, as the app's pages are signed, and shares
    /// their retries: once after a refused client token, and after a failure that may pass.
    private let credentials: SpotifyCredentials
    private var spclientHost: String?
    private let deviceId: String

    // MARK: - Initialization

    init(
        credentials: SpotifyCredentials,
        spclientHost: String? = nil,
        deviceId: String,
    ) {
        self.credentials = credentials
        self.spclientHost = spclientHost
        self.deviceId = deviceId

        debugLog("SPClient", "Initialized")
    }

    /// Reads a request, and throws `requestFailed` naming it unless it is answered 200.
    private nonisolated func fetch(_ request: URLRequest, named name: String) async throws -> Data {
        let (data, status) = try await credentials.read(request)
        guard status == 200 else {
            debugLog("SPClient", "\(name) failed: HTTP \(status), body: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            throw LibrespotError.requestFailed(name, status: status)
        }
        return data
    }

    // MARK: - Context Resolution

    /// An ordered track list resolved from a context uri.
    public struct ResolvedContext: Sendable {
        public var tracks: [String]
        /// The page after these tracks, where the resolve stopped short of the end.
        public var nextPageUrl: String?
    }

    /// Resolves an album, playlist, artist, or station uri into its tracks,
    /// via spclient's context resolver — the same source Spotify's own
    /// clients use, and one that handles every context shape uniformly.
    ///
    /// Its next pages are followed, up to `pageLimit` pages in all, and the page after them named
    /// as `nextPageUrl`. A later page that fails leaves the pages before it; only the first
    /// failing fails the resolve.
    public func resolveContext(_ contextUri: String, pageLimit: Int = 10) async throws -> ResolvedContext {
        let encodedUri = contextUri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? contextUri
        debugLog("SPClient", "Resolving context: \(contextUri)")

        var context = try await fetchContextPage("/context-resolve/v1/\(encodedUri)?device_id=\(deviceId)")
        for _ in 1 ..< max(1, pageLimit) {
            guard let next = context.nextPageUrl else { break }
            do {
                let page = try await fetchContextPage(Self.nextPagePath(next))
                context.tracks += page.tracks
                context.nextPageUrl = page.nextPageUrl
            } catch where !(error is CancellationError) {
                debugLog("SPClient", "Context page failed, keeping \(context.tracks.count) track(s): \(error)")
                context.nextPageUrl = nil
                break
            }
        }

        debugLog("SPClient", "Context resolved: \(context.tracks.count) track(s)\(context.nextPageUrl == nil ? "" : ", more to come")")
        return context
    }

    /// One page of a context, at `path` of spclient.
    private func fetchContextPage(_ path: String) async throws -> ResolvedContext {
        let host = spclientHost ?? "spclient.wg.spotify.com"
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw LibrespotError.invalidState("Context page path: \(path)")
        }
        debugLog("SPClient", "[GET] \(url.absoluteString.prefix(120))")
        var request = URLRequest(url: url)
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        // The deadline is the page's, its retries included.
        let data = try await Self.withTimeout(seconds: 20) { [self, request] in
            try await fetch(request, named: "Context resolve")
        }
        debugLog("SPClient", "Context response received")

        #if DEBUG
            debugLog("SPClient", "Context response \(data.count) bytes: \(data.prefix(400).map { String(format: "%02x", $0) }.joined())")
        #endif
        return Self.parseContextReport(data)
    }

    /// Where a context's next page is asked for. An `hm://` url names a path of spclient's own,
    /// as librespot's `get_next_page` and go-librespot's `hmRequestUrl` read it: a station's next
    /// page, `hm://radio-apollo/v3/tracks/spotify:station:…`, asked of the resolver, was answered
    /// 404, and failed the whole resolve (2026-10-02). Anything else goes through the resolver.
    ///
    /// A station's third page and on are named at `radio-router`, which spclient answers 404; the
    /// same request at `radio-apollo`, where its second is named, answers the next 50 tracks
    /// (2026-10-02). Its `prev_tracks` carry the station on: without them it starts over. They
    /// are cut to `stationPageMemory`.
    nonisolated static func nextPagePath(_ url: String) -> String {
        guard url.hasPrefix("hm://") else { return "/context-resolve/v1/\(url)" }
        let path = "/" + url.dropFirst("hm://".count)
        let router = "/radio-router/"
        return keepingRecentTracks(path.hasPrefix(router) ? "/radio-apollo/" + path.dropFirst(router.count) : path)
    }

    /// How many of the tracks a station played its next page names. A page's url names every
    /// track played before it in `prev_tracks`, the latest page's first, 50 more with each page;
    /// the eleventh page's, 500 tracks and 11,657 characters long, was refused with 431, which
    /// ended the station 500 tracks in (2026-10-02). Those played last are kept, as the ones it
    /// should not play again soon.
    nonisolated static let stationPageMemory = 350

    /// `path` with its `prev_tracks` cut to the first `stationPageMemory`.
    private nonisolated static func keepingRecentTracks(_ path: String) -> String {
        guard let start = path.range(of: "prev_tracks=")?.upperBound else { return path }
        let end = path[start...].firstIndex(of: "&") ?? path.endIndex
        let tracks = path[start ..< end].split(separator: ",")
        return path.replacingCharacters(in: start ..< end, with: tracks.prefix(stationPageMemory).joined(separator: ","))
    }

    /// Parses the context resolver's answer. Despite the protobuf `Accept`
    /// header the endpoint replies **JSON**: `{metadata, pages: [{tracks:
    /// [{uri, uid}], next_page_url}], uri}`.
    nonisolated static func parseContextReport(_ data: Data) -> ResolvedContext {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ResolvedContext(tracks: [])
        }

        var tracks: [String] = []
        var nextPageUrl: String?

        // A next page fetched at its `hm://` url is one page of its own, `{tracks, next_page_url}`,
        // as go-librespot's `loadPage` reads it.
        let pages = json["pages"] as? [[String: Any]] ?? [json]
        for page in pages {
            let pageTracks = page["tracks"] as? [[String: Any]] ?? []
            tracks += pageTracks.compactMap { $0["uri"] as? String }
            if nextPageUrl == nil {
                nextPageUrl = page["next_page_url"] as? String
            }
        }

        return ResolvedContext(tracks: tracks, nextPageUrl: nextPageUrl)
    }

    // MARK: - Timeout

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LibrespotError.timeout("Request timed out after \(seconds)s")
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                // Without this, a thrown deadline awaits the request child —
                // which only ends once URLSession notices its own timeout.
                group.cancelAll()
                throw error
            }
        }
    }
}
