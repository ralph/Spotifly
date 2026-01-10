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
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyAPIError.invalidResponse
        }

        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let durationMs = json["duration_ms"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        var artistName = "Unknown Artist"
        if let artists = json["artists"] as? [[String: Any]] {
            let artistNames = artists.compactMap { $0["name"] as? String }
            artistName = artistNames.joined(separator: ", ")
        }

        var albumName = "Unknown Album"
        var albumImageURL: URL?
        if let album = json["album"] as? [String: Any] {
            albumName = album["name"] as? String ?? "Unknown Album"
            if let images = album["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                albumImageURL = URL(string: urlString)
            }
        }

        var previewURL: URL?
        if let previewUrlString = json["preview_url"] as? String {
            previewURL = URL(string: previewUrlString)
        }

        return TrackMetadata(
            id: id,
            albumImageURL: albumImageURL,
            albumName: albumName,
            artistName: artistName,
            durationMs: durationMs,
            name: name,
            previewURL: previewURL,
        )
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let total = json["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let tracks = items.compactMap { item -> APITrack? in
            guard let track = item["track"] as? [String: Any],
                  let id = track["id"] as? String,
                  let name = track["name"] as? String,
                  let uri = track["uri"] as? String,
                  let durationMs = track["duration_ms"] as? Int
            else {
                return nil
            }

            let addedAt = item["added_at"] as? String

            let artistsArray = track["artists"] as? [[String: Any]]
            let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
            let artistId = artistsArray?.first?["id"] as? String

            let albumData = track["album"] as? [String: Any]
            let albumName = albumData?["name"] as? String
            let albumId = albumData?["id"] as? String
            let albumImages = albumData?["images"] as? [[String: Any]]
            let imageURLString = albumImages?.first?["url"] as? String
            let imageURL = imageURLString.flatMap { URL(string: $0) }

            let externalUrls = track["external_urls"] as? [String: Any]
            let externalUrl = externalUrls?["spotify"] as? String

            return APITrack(
                id: id,
                addedAt: addedAt,
                albumId: albumId,
                albumName: albumName,
                artistId: artistId,
                artistName: artistName,
                durationMs: durationMs,
                externalUrl: externalUrl,
                imageURL: imageURL,
                name: name,
                trackNumber: nil,
                uri: uri,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return SavedTracksResponse(
            hasMore: hasMore,
            nextOffset: nextOffset,
            total: total,
            tracks: tracks,
        )
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
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
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
            guard let results = try? JSONSerialization.jsonObject(with: data) as? [Bool] else {
                throw SpotifyAPIError.invalidResponse
            }
            var dict: [String: Bool] = [:]
            for (index, trackId) in trackIds.enumerated() {
                if index < results.count {
                    dict[trackId] = results[index]
                }
            }
            return dict
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
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
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let tracks = items.compactMap { item -> APITrack? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let durationMs = item["duration_ms"] as? Int,
                      let trackNumber = item["track_number"] as? Int
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let externalUrls = item["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return APITrack(
                    id: id,
                    addedAt: nil,
                    albumId: albumId,
                    albumName: albumName,
                    artistId: artistId,
                    artistName: artistName,
                    durationMs: durationMs,
                    externalUrl: externalUrl,
                    imageURL: imageURL,
                    name: name,
                    trackNumber: trackNumber,
                    uri: uri,
                )
            }

            return tracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let tracks = items.compactMap { item -> APITrack? in
                guard let track = item["track"] as? [String: Any],
                      let id = track["id"] as? String,
                      let name = track["name"] as? String,
                      let uri = track["uri"] as? String,
                      let durationMs = track["duration_ms"] as? Int
                else {
                    return nil
                }

                let addedAt = item["added_at"] as? String

                let artistsArray = track["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = track["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = track["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return APITrack(
                    id: id,
                    addedAt: addedAt,
                    albumId: albumId,
                    albumName: albumName,
                    artistId: artistId,
                    artistName: artistName,
                    durationMs: durationMs,
                    externalUrl: externalUrl,
                    imageURL: imageURL,
                    name: name,
                    trackNumber: nil,
                    uri: uri,
                )
            }

            return tracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracksArray = json["tracks"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let tracks = tracksArray.compactMap { track -> APITrack? in
                guard let id = track["id"] as? String,
                      let name = track["name"] as? String,
                      let uri = track["uri"] as? String,
                      let durationMs = track["duration_ms"] as? Int
                else {
                    return nil
                }

                let artistsArray = track["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let trackArtistId = artistsArray?.first?["id"] as? String

                let albumData = track["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                let externalUrls = track["external_urls"] as? [String: Any]
                let externalUrl = externalUrls?["spotify"] as? String

                return APITrack(
                    id: id,
                    addedAt: nil,
                    albumId: albumId,
                    albumName: albumName,
                    artistId: trackArtistId,
                    artistName: artistName,
                    durationMs: durationMs,
                    externalUrl: externalUrl,
                    imageURL: imageURL,
                    name: name,
                    trackNumber: nil,
                    uri: uri,
                )
            }

            return tracks
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.notFound
        default:
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw SpotifyAPIError.apiError(message)
            }
            throw SpotifyAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
}
