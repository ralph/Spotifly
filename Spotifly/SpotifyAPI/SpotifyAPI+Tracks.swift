//
//  SpotifyAPI+Tracks.swift
//  Spotifly
//
//  Track-related API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - Single Track

    /// Fetches a single track from Spotify Web API
    static func fetchTrack(trackId: String, accessToken: String) async throws -> APITrack {
        let urlString = "\(baseURL)/tracks/\(trackId)?market=from_token"

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
                let track = try JSONDecoder().decode(TrackCodable.self, from: data)
                return track.toAPITrack()
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

    // MARK: - Multiple Tracks

    /// The most IDs `/v1/tracks` accepts in one request.
    private static let trackBatchLimit = 50

    /// Fetches multiple tracks by their IDs.
    /// Returns a dictionary mapping track ID to APITrack, omitting IDs Spotify has no
    /// track for — an ID that does not resolve for this market comes back as a `null`
    /// entry, and callers read its absence as "asked, and there is nothing".
    ///
    /// Chunking lives here rather than in the caller because 50 is the endpoint's limit,
    /// not a property of anything that wants tracks.
    static func fetchTracks(accessToken: String, trackIds: [String]) async throws -> [String: APITrack] {
        guard !trackIds.isEmpty else { return [:] }

        var result: [String: APITrack] = [:]
        for batch in stride(from: 0, to: trackIds.count, by: trackBatchLimit) {
            let ids = Array(trackIds[batch ..< min(batch + trackBatchLimit, trackIds.count)])
            try await result.merge(fetchTrackBatch(accessToken: accessToken, trackIds: ids)) { current, _ in current }
        }
        return result
    }

    /// One `/v1/tracks?ids=` request, at most `trackBatchLimit` IDs.
    private static func fetchTrackBatch(accessToken: String, trackIds: [String]) async throws -> [String: APITrack] {
        let ids = trackIds.joined(separator: ",")
        let urlString = "\(baseURL)/tracks?ids=\(ids)&market=from_token"

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
                // Spotify answers positionally, with null where it has no track, so the
                // response is zipped back onto the requested IDs rather than trusting
                // each object to carry the id that was asked for.
                let decoded = try JSONDecoder().decode(TracksCodable.self, from: data)
                var dict: [String: APITrack] = [:]
                for (trackId, track) in zip(trackIds, decoded.tracks) {
                    guard let track else { continue }

                    dict[trackId] = track.toAPITrack()
                }
                return dict
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Saved Tracks (Favorites)

    /// Fetches user's saved tracks (favorites) from Spotify Web API
    static func fetchUserSavedTracks(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> SavedTracksResponse {
        let urlString = "\(baseURL)/me/tracks?limit=\(limit)&offset=\(offset)&fields=items(added_at,track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify),linked_from(id,uri))),total,next&market=from_token"

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
                let decoded = try JSONDecoder().decode(SavedTracksCodable.self, from: data)
                let tracks = decoded.items.map { item in
                    item.track.toAPITrack(addedAt: item.addedAt)
                }
                let hasMore = decoded.next != nil
                return SavedTracksResponse(
                    hasMore: hasMore,
                    nextOffset: hasMore ? offset + limit : nil,
                    total: decoded.total,
                    tracks: tracks,
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

    /// Saves a track to user's library
    static func saveTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [trackId]])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 201:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Checks if multiple tracks are saved in user's library
    static func checkSavedTracks(accessToken: String, trackIds: [String]) async throws -> [String: Bool] {
        guard !trackIds.isEmpty else { return [:] }

        let ids = trackIds.joined(separator: ",")
        let urlString = "\(baseURL)/me/tracks/contains?ids=\(ids)"

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
                let results = try JSONDecoder().decode([Bool].self, from: data)
                var dict: [String: Bool] = [:]
                for (index, trackId) in trackIds.enumerated() where index < results.count {
                    dict[trackId] = results[index]
                }
                return dict
            } catch {
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    /// Removes a track from user's library
    static func removeSavedTrack(accessToken: String, trackId: String) async throws {
        let urlString = "\(baseURL)/me/tracks"

        debugLog("SpotifyAPI", "[DELETE] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ids": [trackId]])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Album Tracks

    /// Fetches tracks for a specific album
    static func fetchAlbumTracks(
        accessToken: String,
        albumId: String,
        albumName: String? = nil,
        images: ImageSet = ImageSet.empty,
    ) async throws -> [APITrack] {
        let urlString = "\(baseURL)/albums/\(albumId)/tracks?limit=50&fields=items(id,name,uri,duration_ms,track_number,artists(id,name),external_urls(spotify),linked_from(id,uri))&market=from_token"

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
                let decoded = try JSONDecoder().decode(AlbumTracksCodable.self, from: data)
                return decoded.items.map { $0.toAPITrack(albumId: albumId, albumName: albumName, images: images) }
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

    // MARK: - Playlist Tracks

    /// Fetches tracks for a specific playlist, paginating through all items
    static func fetchPlaylistTracks(accessToken: String, playlistId: String) async throws -> [APITrack] {
        var tracks: [APITrack] = []
        var nextURLString: String? =
            "\(baseURL)/playlists/\(playlistId)/items?limit=50&fields=items(added_at,track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify),linked_from(id,uri))),next&market=from_token"

        while let urlString = nextURLString {
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
                    let decoded = try JSONDecoder().decode(PlaylistItemsCodable.self, from: data)
                    tracks += decoded.items.compactMap { item in
                        item.track?.toAPITrack(addedAt: item.addedAt)
                    }
                    nextURLString = decoded.next
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

        return tracks
    }
}
