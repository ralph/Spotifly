//
//  SpotifyAPI+Artists.swift
//  Spotifly
//
//  Artist-related API calls.
//

import Foundation
import os

extension SpotifyAPI {
    // MARK: - Artist Details

    /// Fetches a single artist's details from Spotify Web API
    static func fetchArtistDetails(accessToken: String, artistId: String) async throws -> APIArtist {
        let urlString = "\(baseURL)/artists/\(artistId)?fields=id,name,uri,genres,followers(total),images"
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
              let uri = json["uri"] as? String
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let genres = json["genres"] as? [String] ?? []
        let followers = (json["followers"] as? [String: Any])?["total"] as? Int ?? 0

        var imageURL: URL?
        if let images = json["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlString = firstImage["url"] as? String
        {
            imageURL = URL(string: urlString)
        }

        return APIArtist(
            id: id,
            followers: followers,
            genres: genres,
            imageURL: imageURL,
            name: name,
            uri: uri,
        )
    }

    // MARK: - User's Followed Artists

    /// Fetches user's followed artists from Spotify Web API
    static func fetchUserArtists(accessToken: String, limit: Int = 50, after: String? = nil) async throws -> ArtistsResponse {
        var urlString = "\(baseURL)/me/following?type=artist&limit=\(limit)"
        if let cursor = after {
            urlString += "&after=\(cursor)"
        }
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
              let artistsContainer = json["artists"] as? [String: Any],
              let items = artistsContainer["items"] as? [[String: Any]],
              let total = artistsContainer["total"] as? Int
        else {
            throw SpotifyAPIError.invalidResponse
        }

        let artists = items.compactMap { item -> APIArtist? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String
            else {
                return nil
            }

            let genres = (item["genres"] as? [String]) ?? []
            let followersDict = item["followers"] as? [String: Any]
            let followers = followersDict?["total"] as? Int ?? 0

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            return APIArtist(
                id: id,
                followers: followers,
                genres: genres,
                imageURL: imageURL,
                name: name,
                uri: uri,
            )
        }

        let cursors = artistsContainer["cursors"] as? [String: Any]
        let afterCursor = cursors?["after"] as? String

        return ArtistsResponse(
            artists: artists,
            hasMore: afterCursor != nil,
            nextCursor: afterCursor,
            total: total,
        )
    }

    // MARK: - User's Top Artists

    /// Fetches user's top artists from Spotify Web API
    static func fetchUserTopArtists(
        accessToken: String,
        timeRange: TopItemsTimeRange = .mediumTerm,
        limit: Int = 50,
        offset: Int = 0,
    ) async throws -> TopArtistsResponse {
        let urlString = "\(baseURL)/me/top/artists?time_range=\(timeRange.rawValue)&limit=\(limit)&offset=\(offset)"
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

        let artists = items.compactMap { item -> APIArtist? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let uri = item["uri"] as? String
            else {
                return nil
            }

            let genres = (item["genres"] as? [String]) ?? []
            let followersDict = item["followers"] as? [String: Any]
            let followers = followersDict?["total"] as? Int ?? 0

            var imageURL: URL?
            if let images = item["images"] as? [[String: Any]],
               let firstImage = images.first,
               let urlString = firstImage["url"] as? String
            {
                imageURL = URL(string: urlString)
            }

            return APIArtist(
                id: id,
                followers: followers,
                genres: genres,
                imageURL: imageURL,
                name: name,
                uri: uri,
            )
        }

        let nextOffset = offset + limit
        let hasMore = nextOffset < total

        return TopArtistsResponse(
            artists: artists,
            hasMore: hasMore,
            nextOffset: hasMore ? nextOffset : nil,
            total: total,
        )
    }
}
