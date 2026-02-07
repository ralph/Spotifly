//
//  SpotifyAPI+Search.swift
//  Spotifly
//
//  Search API calls.
//

import Foundation

extension SpotifyAPI {
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
                let decoded = try JSONDecoder().decode(SearchResultsCodable.self, from: data)

                // Convert tracks
                let tracks: [Track] = decoded.tracks?.items?.map { track in
                    let artist = track.artists?.first
                    return Track(
                        id: track.id,
                        name: track.name,
                        uri: track.uri,
                        durationMs: track.durationMs,
                        trackNumber: track.trackNumber,
                        externalUrl: track.externalUrls?.spotify,
                        albumId: track.album?.id,
                        artistId: artist?.id,
                        artistName: artist?.name ?? "Unknown",
                        albumName: track.album?.name,
                        imageURL: (track.album?.images?.first?.url).flatMap { URL(string: $0) },
                    )
                } ?? []

                // Convert albums
                let albums: [Album] = decoded.albums?.items?.map { album in
                    let artist = album.artists?.first
                    return Album(
                        id: album.id,
                        name: album.name,
                        uri: album.uri,
                        imageURL: (album.images?.first?.url).flatMap { URL(string: $0) },
                        releaseDate: album.releaseDate,
                        albumType: album.albumType,
                        externalUrl: album.externalUrls?.spotify,
                        artistId: artist?.id,
                        artistName: artist?.name ?? "Unknown",
                        trackIds: [],
                        totalDurationMs: nil,
                        knownTrackCount: album.totalTracks ?? 0,
                    )
                } ?? []

                // Convert artists
                let artists: [Artist] = decoded.artists?.items?.compactMap { artist -> Artist? in
                    guard let id = artist.id, let uri = artist.uri else { return nil }
                    return Artist(
                        id: id,
                        name: artist.name,
                        uri: uri,
                        imageURL: (artist.images?.first?.url).flatMap { URL(string: $0) },
                        genres: artist.genres ?? [],
                        externalUrl: artist.externalUrls?.spotify,
                    )
                } ?? []

                // Convert playlists (filter out null items for deleted/unavailable playlists)
                let playlists: [Playlist] = decoded.playlists?.items?.compactMap { playlist -> Playlist? in
                    guard let playlist else { return nil }
                    return Playlist(
                        id: playlist.id,
                        name: playlist.name,
                        description: playlist.description,
                        imageURL: (playlist.images?.first?.url).flatMap { URL(string: $0) },
                        uri: playlist.uri,
                        isPublic: playlist.public ?? true,
                        ownerId: playlist.owner.id,
                        ownerName: playlist.owner.displayName ?? playlist.owner.id,
                        externalUrl: playlist.externalUrls?.spotify,
                        trackIds: [],
                        totalDurationMs: nil,
                        knownTrackCount: playlist.items?.total ?? 0,
                    )
                } ?? []

                return SearchResults(
                    albums: albums,
                    artists: artists,
                    playlists: playlists,
                    tracks: tracks,
                )
            } catch {
                debugLog("SpotifyAPI", "[Search] Decoding error: \(error)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    debugLog("SpotifyAPI", "[Search] Response: \(String(jsonString.prefix(500)))")
                }
                throw SpotifyAPIError.invalidResponse
            }
        case 401:
            throw SpotifyAPIError.unauthorized
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
}
