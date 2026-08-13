//
//  SpotifyAPI+Artists.swift
//  Spotifly
//
//  Artist-related API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - User's Top Artists

    /// Fetches user's top artists from Spotify Web API
    static func fetchUserTopArtists(
        accessToken: String,
        timeRange: TopItemsTimeRange = .mediumTerm,
        limit: Int = 50,
        offset: Int = 0,
    ) async throws -> TopArtistsResponse {
        let urlString = "\(baseURL)/me/top/artists?time_range=\(timeRange.rawValue)&limit=\(limit)&offset=\(offset)"

        debugLog("SpotifyAPI", "[GET] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(TopArtistsCodable.self, from: data)
                let artists = decoded.items.compactMap { $0.toAPIArtist() }
                let nextOffset = offset + limit
                let hasMore = nextOffset < decoded.total
                return TopArtistsResponse(
                    artists: artists,
                    hasMore: hasMore,
                    nextOffset: hasMore ? nextOffset : nil,
                    total: decoded.total,
                )
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - User's Top Tracks

    /// Fetches user's top tracks from Spotify Web API
    static func fetchUserTopTracks(
        accessToken: String,
        timeRange: TopItemsTimeRange = .mediumTerm,
        limit: Int = 50,
        offset: Int = 0,
    ) async throws -> TopTracksResponse {
        let urlString = "\(baseURL)/me/top/tracks?time_range=\(timeRange.rawValue)&limit=\(limit)&offset=\(offset)"

        debugLog("SpotifyAPI", "[GET] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(TopTracksCodable.self, from: data)
                let tracks = decoded.items.map { $0.toAPITrack() }
                let nextOffset = offset + limit
                let hasMore = nextOffset < decoded.total
                return TopTracksResponse(
                    tracks: tracks,
                    hasMore: hasMore,
                    nextOffset: hasMore ? nextOffset : nil,
                    total: decoded.total,
                )
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
