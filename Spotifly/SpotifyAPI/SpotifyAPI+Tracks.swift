//
//  SpotifyAPI+Tracks.swift
//  Spotifly
//
//  Track-related API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Single Track

    /// Fetches track metadata from Spotify Web API
    static func fetchTrackMetadata(trackId: String, accessToken: String) async throws -> TrackMetadata {
        let urlString = "\(baseURL)/tracks/\(trackId)?fields=id,name,duration_ms,artists(name),album(name,images),preview_url"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
                return track.toTrackMetadata()
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

    /// Fetches multiple tracks by their IDs (batch fetch, up to 50 at a time)
    /// Returns a dictionary mapping track ID to APITrack (for found tracks)
    static func fetchTracks(accessToken: String, trackIds: [String]) async throws -> [String: APITrack] {
        guard !trackIds.isEmpty else { return [:] }

        // Spotify API allows max 50 tracks per request
        let batchSize = 50
        var result: [String: APITrack] = [:]

        for batchStart in stride(from: 0, to: trackIds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, trackIds.count)
            let batch = Array(trackIds[batchStart ..< batchEnd])
            let ids = batch.joined(separator: ",")

            let urlString = "\(baseURL)/tracks?ids=\(ids)"
            #if DEBUG
                apiLogger.debug("[GET] \(urlString)")
            #endif

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
                    let decoded = try JSONDecoder().decode(MultipleTracksCodable.self, from: data)
                    for track in decoded.tracks {
                        // track can be null if not found
                        if let track {
                            result[track.id] = track.toAPITrack()
                        }
                    }
                } catch {
                    throw SpotifyAPIError.invalidResponse
                }
            case 401:
                throw SpotifyAPIError.unauthorized
            default:
                try throwAPIError(data: data, statusCode: httpResponse.statusCode)
            }
        }

        return result
    }

    // MARK: - Saved Tracks (Favorites)

    /// Fetches user's saved tracks (favorites) from Spotify Web API
    static func fetchUserSavedTracks(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> SavedTracksResponse {
        let urlString = "\(baseURL)/me/tracks?limit=\(limit)&offset=\(offset)&fields=items(added_at,track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify))),total,next"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
        let urlString = "\(baseURL)/me/tracks?ids=\(trackId)"
        #if DEBUG
            apiLogger.debug("[PUT] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

    /// Checks if a track is saved in user's library
    static func checkSavedTrack(accessToken: String, trackId: String) async throws -> Bool {
        let results = try await checkSavedTracks(accessToken: accessToken, trackIds: [trackId])
        return results[trackId] ?? false
    }

    /// Checks if multiple tracks are saved in user's library
    static func checkSavedTracks(accessToken: String, trackIds: [String]) async throws -> [String: Bool] {
        guard !trackIds.isEmpty else { return [:] }

        let ids = trackIds.joined(separator: ",")
        let urlString = "\(baseURL)/me/tracks/contains?ids=\(ids)"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
        let urlString = "\(baseURL)/me/tracks?ids=\(trackId)"
        #if DEBUG
            apiLogger.debug("[DELETE] \(urlString)")
        #endif

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        imageURL: URL? = nil,
    ) async throws -> [APITrack] {
        let urlString = "\(baseURL)/albums/\(albumId)/tracks?limit=50&fields=items(id,name,uri,duration_ms,track_number,artists(id,name),external_urls(spotify))"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
                return decoded.items.map { $0.toAPITrack(albumId: albumId, albumName: albumName, imageURL: imageURL) }
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

    /// Fetches tracks for a specific playlist
    static func fetchPlaylistTracks(accessToken: String, playlistId: String) async throws -> [APITrack] {
        let urlString = "\(baseURL)/playlists/\(playlistId)/tracks?limit=100&fields=items(added_at,track(id,name,uri,duration_ms,artists(id,name),album(id,name,images),external_urls(spotify)))&market=from_token"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
                let decoded = try JSONDecoder().decode(PlaylistTracksCodable.self, from: data)
                return decoded.items.compactMap { item in
                    item.track?.toAPITrack(addedAt: item.addedAt)
                }
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

    // MARK: - Artist Top Tracks

    /// Fetches top tracks for a specific artist
    static func fetchArtistTopTracks(accessToken: String, artistId: String) async throws -> [APITrack] {
        let urlString = "\(baseURL)/artists/\(artistId)/top-tracks?market=from_token"
        #if DEBUG
            apiLogger.debug("[GET] \(urlString)")
        #endif

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
                let decoded = try JSONDecoder().decode(ArtistTopTracksCodable.self, from: data)
                return decoded.tracks.map { $0.toAPITrack() }
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
