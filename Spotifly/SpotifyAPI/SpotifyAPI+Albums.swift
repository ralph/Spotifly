//
//  SpotifyAPI+Albums.swift
//  Spotifly
//
//  Album-related API calls.
//

import Foundation

extension SpotifyAPI {
    // MARK: - Album Details

    /// Fetches a single album's details from Spotify Web API
    static func fetchAlbumDetails(accessToken: String, albumId: String) async throws -> APIAlbum {
        let urlString = "\(baseURL)/albums/\(albumId)?fields=id,name,uri,total_tracks,release_date,artists(id,name),images,tracks(items(duration_ms)),external_urls(spotify)"

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
                let album = try JSONDecoder().decode(AlbumCodable.self, from: data)
                return album.toAPIAlbum()
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

    // MARK: - User's Saved Albums

    /// Fetches user's saved albums from Spotify Web API
    static func fetchUserAlbums(accessToken: String, limit: Int = 50, offset: Int = 0) async throws -> AlbumsResponse {
        let urlString = "\(baseURL)/me/albums?limit=\(limit)&offset=\(offset)&fields=items(album(id,name,uri,total_tracks,release_date,album_type,artists(id,name),images,tracks(items(duration_ms)),external_urls(spotify))),total,next"

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
                let decoded = try JSONDecoder().decode(UserAlbumsCodable.self, from: data)
                let albums = decoded.items.map { $0.album.toAPIAlbum() }
                let hasMore = decoded.next != nil
                return AlbumsResponse(
                    albums: albums,
                    hasMore: hasMore,
                    nextOffset: hasMore ? offset + limit : nil,
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

    // MARK: - Artist Albums

    /// Fetches albums for a specific artist
    static func fetchArtistAlbums(
        accessToken: String,
        artistId: String,
        limit: Int = 50,
    ) async throws -> [APIAlbum] {
        let urlString = "\(baseURL)/artists/\(artistId)/albums?include_groups=album,single&market=from_token&limit=\(limit)"

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
                let decoded = try JSONDecoder().decode(ArtistAlbumsCodable.self, from: data)
                return decoded.items.map { $0.toAPIAlbum() }
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

    // MARK: - Remove Saved Album

    /// Removes an album from the user's library
    static func removeUserAlbum(accessToken: String, albumId: String) async throws {
        let urlString = "\(baseURL)/me/library"

        debugLog("SpotifyAPI", "[DELETE] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["uris": ["spotify:album:\(albumId)"]])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify library")
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Save Album

    /// Saves an album to the user's library
    static func saveUserAlbum(accessToken: String, albumId: String) async throws {
        let urlString = "\(baseURL)/me/library"

        debugLog("SpotifyAPI", "[PUT] \(urlString)")

        guard let url = URL(string: urlString) else {
            throw SpotifyAPIError.invalidURI
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["uris": ["spotify:album:\(albumId)"]])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 403:
            throw SpotifyAPIError.apiError("Not authorized to modify library")
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
