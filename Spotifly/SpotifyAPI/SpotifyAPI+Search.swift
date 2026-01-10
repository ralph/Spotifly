//
//  SpotifyAPI+Search.swift
//  Spotifly
//
//  Search and recommendations API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Recommendations

    /// Fetches track recommendations based on a seed track (for "Start Radio" feature)
    static func fetchRecommendations(
        accessToken: String,
        seedTrackId: String,
        limit: Int = 50,
    ) async throws -> [APITrack] {
        let urlString = "\(baseURL)/recommendations?seed_tracks=\(seedTrackId)&limit=\(limit)"
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
                  let tracks = json["tracks"] as? [[String: Any]]
            else {
                throw SpotifyAPIError.invalidResponse
            }

            let recommendedTracks = tracks.compactMap { item -> APITrack? in
                guard let id = item["id"] as? String,
                      let name = item["name"] as? String,
                      let uri = item["uri"] as? String,
                      let durationMs = item["duration_ms"] as? Int
                else {
                    return nil
                }

                let artistsArray = item["artists"] as? [[String: Any]]
                let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                let artistId = artistsArray?.first?["id"] as? String

                let albumData = item["album"] as? [String: Any]
                let albumName = albumData?["name"] as? String ?? ""
                let albumId = albumData?["id"] as? String
                let albumImages = albumData?["images"] as? [[String: Any]]
                let imageURLString = albumImages?.first?["url"] as? String
                let imageURL = imageURLString.flatMap { URL(string: $0) }

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
                    trackNumber: nil,
                    uri: uri,
                )
            }

            return recommendedTracks
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

    // MARK: - Search

    /// Searches Spotify for tracks, albums, artists, and playlists
    static func search(
        accessToken: String,
        query: String,
        types: [SearchType] = [.track, .album, .artist, .playlist],
        limit: Int = 20,
    ) async throws -> SearchResults {
        let typesString = types.map(\.rawValue).joined(separator: ",")
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(baseURL)/search?q=\(encodedQuery)&type=\(typesString)&limit=\(limit)&market=from_token"
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyAPIError.invalidResponse
            }

            // Parse tracks
            var tracks: [Track] = []
            if let tracksObj = json["tracks"] as? [String: Any],
               let items = tracksObj["items"] as? [[String: Any]]
            {
                tracks = items.compactMap { item -> Track? in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String,
                          let durationMs = item["duration_ms"] as? Int
                    else {
                        return nil
                    }

                    let artistsArray = item["artists"] as? [[String: Any]]
                    let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                    let artistId = artistsArray?.first?["id"] as? String

                    let albumData = item["album"] as? [String: Any]
                    let albumName = albumData?["name"] as? String
                    let albumId = albumData?["id"] as? String
                    let albumImages = albumData?["images"] as? [[String: Any]]
                    let imageURLString = albumImages?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    let externalUrls = item["external_urls"] as? [String: Any]
                    let externalUrl = externalUrls?["spotify"] as? String

                    return Track(
                        id: id,
                        name: name,
                        uri: uri,
                        durationMs: durationMs,
                        trackNumber: nil,
                        externalUrl: externalUrl,
                        albumId: albumId,
                        artistId: artistId,
                        artistName: artistName,
                        albumName: albumName,
                        imageURL: imageURL,
                    )
                }
            }

            // Parse albums
            var albums: [Album] = []
            if let albumsObj = json["albums"] as? [String: Any],
               let items = albumsObj["items"] as? [[String: Any]]
            {
                albums = items.compactMap { item -> Album? in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String
                    else {
                        return nil
                    }

                    let artistsArray = item["artists"] as? [[String: Any]]
                    let artistName = artistsArray?.first?["name"] as? String ?? "Unknown"
                    let artistId = artistsArray?.first?["id"] as? String

                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    let totalTracks = item["total_tracks"] as? Int ?? 0
                    let releaseDate = item["release_date"] as? String

                    return Album(
                        id: id,
                        name: name,
                        uri: uri,
                        imageURL: imageURL,
                        releaseDate: releaseDate,
                        albumType: nil,
                        externalUrl: nil,
                        artistId: artistId,
                        artistName: artistName,
                        trackIds: [],
                        totalDurationMs: nil,
                        knownTrackCount: totalTracks,
                    )
                }
            }

            // Parse artists
            var artists: [Artist] = []
            if let artistsObj = json["artists"] as? [String: Any],
               let items = artistsObj["items"] as? [[String: Any]]
            {
                artists = items.compactMap { item -> Artist? in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String
                    else {
                        return nil
                    }

                    let genres = item["genres"] as? [String] ?? []
                    let followersDict = item["followers"] as? [String: Any]
                    let followers = followersDict?["total"] as? Int ?? 0

                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    return Artist(
                        id: id,
                        name: name,
                        uri: uri,
                        imageURL: imageURL,
                        genres: genres,
                        followers: followers,
                    )
                }
            }

            // Parse playlists
            var playlists: [Playlist] = []
            if let playlistsObj = json["playlists"] as? [String: Any],
               let items = playlistsObj["items"] as? [[String: Any]]
            {
                playlists = items.compactMap { item -> Playlist? in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String,
                          let owner = item["owner"] as? [String: Any],
                          let ownerId = owner["id"] as? String
                    else {
                        return nil
                    }

                    let ownerName = owner["display_name"] as? String ?? ownerId
                    let description = item["description"] as? String

                    let images = item["images"] as? [[String: Any]]
                    let imageURLString = images?.first?["url"] as? String
                    let imageURL = imageURLString.flatMap { URL(string: $0) }

                    let tracksObj = item["tracks"] as? [String: Any]
                    let trackCount = tracksObj?["total"] as? Int ?? 0

                    return Playlist(
                        id: id,
                        name: name,
                        description: description,
                        imageURL: imageURL,
                        uri: uri,
                        isPublic: true,
                        ownerId: ownerId,
                        ownerName: ownerName,
                        trackIds: [],
                        totalDurationMs: nil,
                        knownTrackCount: trackCount,
                    )
                }
            }

            return SearchResults(
                albums: albums,
                artists: artists,
                playlists: playlists,
                tracks: tracks,
            )

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
}
