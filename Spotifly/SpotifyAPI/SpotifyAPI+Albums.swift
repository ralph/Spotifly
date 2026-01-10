//
//  SpotifyAPI+Albums.swift
//  Spotifly
//
//  Album-related API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Album Details

    /// Fetches a single album's details from Spotify Web API
    static func fetchAlbumDetails(accessToken: String, albumId: String) async throws -> APIAlbum {
        let urlString = "\(baseURL)/albums/\(albumId)?fields=id,name,uri,total_tracks,release_date,artists(id,name),images,tracks(items(duration_ms)),external_urls(spotify)"
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
              let uri = json["uri"] as? String,
              let totalTracks = json["total_tracks"] as? Int,
              let releaseDate = json["release_date"] as? String,
              let artists = json["artists"] as? [[String: Any]]
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let artistName = artists.first?["name"] as? String ?? "Unknown Artist"
        let artistId = artists.first?["id"] as? String

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        var totalDurationMs: Int?
        if let tracksObj = json["tracks"] as? [String: Any],
           let items = tracksObj["items"] as? [[String: Any]]
        {
            let durations = items.compactMap { $0["duration_ms"] as? Int }
            if !durations.isEmpty {
                totalDurationMs = durations.reduce(0, +)
            }
        }

        let externalUrls = json["external_urls"] as? [String: Any]
        let externalUrl = externalUrls?["spotify"] as? String

        return APIAlbum(
            id: id,
            albumType: nil,
            artistId: artistId,
            artistName: artistName,
            externalUrl: externalUrl,
            imageURL: imageURL,
            name: name,
            releaseDate: releaseDate,
            totalDurationMs: totalDurationMs,
            trackCount: totalTracks,
            uri: uri,
        )
    }

    // MARK: - User's Saved Albums

    /// Fetches user's saved albums from Spotify Web API
    static func fetchUserAlbums(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> AlbumsResponse {
        let urlString = "\(baseURL)/me/albums?limit=\(limit)&offset=\(offset)&fields=items(album(id,name,uri,total_tracks,release_date,album_type,artists(name),images,tracks(items(duration_ms)))),total,next"
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

        let albums = items.compactMap { item -> APIAlbum? in
            guard let album = item["album"] as? [String: Any],
                  let id = album["id"] as? String,
                  let name = album["name"] as? String,
                  let uri = album["uri"] as? String,
                  let totalTracks = album["total_tracks"] as? Int,
                  let releaseDate = album["release_date"] as? String
            else {
                return nil
            }

            let artistsArray = album["artists"] as? [[String: Any]]
            let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"

            var imageURL: URL?
            if let images = album["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            let albumType = album["album_type"] as? String

            var totalDurationMs: Int?
            if let tracksObj = album["tracks"] as? [String: Any],
               let trackItems = tracksObj["items"] as? [[String: Any]]
            {
                let durations = trackItems.compactMap { $0["duration_ms"] as? Int }
                if !durations.isEmpty {
                    totalDurationMs = durations.reduce(0, +)
                }
            }

            return APIAlbum(
                id: id,
                albumType: albumType,
                artistId: nil,
                artistName: artistName,
                externalUrl: nil,
                imageURL: imageURL,
                name: name,
                releaseDate: releaseDate,
                totalDurationMs: totalDurationMs,
                trackCount: totalTracks,
                uri: uri,
            )
        }

        let next = json["next"] as? String
        let hasMore = next != nil
        let nextOffset = hasMore ? offset + limit : nil

        return AlbumsResponse(
            albums: albums,
            hasMore: hasMore,
            nextOffset: nextOffset,
            total: total,
        )
    }

    // MARK: - Artist Albums

    /// Fetches albums for a specific artist
    static func fetchArtistAlbums(
        accessToken: String,
        artistId: String,
        limit: Int = 50,
    ) async throws -> [APIAlbum] {
        let urlString = "\(baseURL)/artists/\(artistId)/albums?include_groups=album,single&market=from_token&limit=\(limit)"
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

            let albums = items.compactMap { item -> APIAlbum? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let totalTracks = item["total_tracks"] as? Int,
                      let releaseDate = item["release_date"] as? String
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"

                let images = item["images"] as? [[String: Any]]
                let imageURLString = images?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

                return APIAlbum(
                    id: id,
                    albumType: nil,
                    artistId: nil,
                    artistName: artistName,
                    externalUrl: nil,
                    imageURL: imageURL,
                    name: name,
                    releaseDate: releaseDate,
                    totalDurationMs: nil,
                    trackCount: totalTracks,
                    uri: uri,
                )
            }

            return albums
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

    // MARK: - New Releases

    /// Fetches new album releases from Spotify Web API
    static func fetchNewReleases(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> NewReleasesResponse {
        let urlString = "\(baseURL)/browse/new-releases?limit=\(limit)&offset=\(offset)"
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
              let albumsContainer = json["albums"] as? [String: Any],
              let items = albumsContainer["items"] as? [[String: Any]],
              let total = albumsContainer["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let albums = items.compactMap { item -> APIAlbum? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String
            else {
                return nil
            }

            let artistsArray = item["artists"] as? [[String: Any]]
            let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            let trackCount = item["total_tracks"] as? Int ?? 0
            let releaseDate = (item["release_date"] as? String) ?? ""
            let albumType = (item["album_type"] as? String) ?? "album"

            return APIAlbum(
                id: id,
                albumType: albumType,
                artistId: nil,
                artistName: artistName,
                externalUrl: nil,
                imageURL: imageURL,
                name: name,
                releaseDate: releaseDate,
                totalDurationMs: nil,
                trackCount: trackCount,
                uri: uri,
            )
        }

        let nextOffset = offset + limit
        let hasMore = nextOffset < total

        return NewReleasesResponse(
            albums: albums,
            hasMore: hasMore,
            nextOffset: hasMore ? nextOffset : nil,
            total: total,
        )
    }
}
