//
//  RecentlyPlayedViewModel.swift
//  Spotifly
//
//  Manages recently played content
//

import SwiftUI

@MainActor
@Observable
final class RecentlyPlayedViewModel {
    var recentTracks: [SearchTrack] = []
    var recentAlbums: [SearchAlbum] = []
    var recentArtists: [SearchArtist] = []
    var recentPlaylists: [SearchPlaylist] = []
    var isLoading = false
    var errorMessage: String?

    func loadRecentlyPlayed(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchRecentlyPlayed(accessToken: accessToken, limit: 50)

            // Process tracks - get top 10 unique tracks
            var uniqueTracks: [String: SearchTrack] = [:]
            for item in response.items {
                if uniqueTracks[item.track.id] == nil {
                    uniqueTracks[item.track.id] = item.track
                }
            }
            recentTracks = Array(uniqueTracks.values.prefix(10))

            // Process albums from context
            var uniqueAlbums: [String: (uri: String, name: String, artistName: String, imageURL: URL?)] = [:]
            for item in response.items {
                if let context = item.context, context.type == "album" {
                    let albumId = extractId(from: context.uri)
                    if uniqueAlbums[albumId] == nil {
                        uniqueAlbums[albumId] = (
                            uri: context.uri,
                            name: item.track.albumName,
                            artistName: item.track.artistName,
                            imageURL: item.track.imageURL,
                        )
                    }
                }
            }

            // Convert to SearchAlbum
            recentAlbums = uniqueAlbums.map { id, info in
                SearchAlbum(
                    id: id,
                    name: info.name,
                    uri: info.uri,
                    artistName: info.artistName,
                    imageURL: info.imageURL,
                    totalTracks: 0,
                    releaseDate: "",
                )
            }

            // Process artists from context
            var uniqueArtists: [String: (uri: String, name: String)] = [:]
            for item in response.items {
                if let context = item.context, context.type == "artist" {
                    let artistId = extractId(from: context.uri)
                    if uniqueArtists[artistId] == nil {
                        uniqueArtists[artistId] = (
                            uri: context.uri,
                            name: item.track.artistName,
                        )
                    }
                }
            }

            recentArtists = uniqueArtists.map { id, info in
                SearchArtist(
                    id: id,
                    name: info.name,
                    uri: info.uri,
                    imageURL: nil,
                    genres: [],
                    followers: 0,
                )
            }

            // Process playlists from context
            var uniquePlaylistIds: Set<String> = []
            for item in response.items {
                if let context = item.context, context.type == "playlist" {
                    let playlistId = extractId(from: context.uri)
                    uniquePlaylistIds.insert(playlistId)
                }
            }

            // Fetch playlist details concurrently and filter out empty playlists
            print("DEBUG: Fetching \(uniquePlaylistIds.count) unique playlists concurrently")
            let fetchedPlaylists = await withTaskGroup(of: SearchPlaylist?.self) { group in
                for playlistId in uniquePlaylistIds {
                    group.addTask {
                        print("DEBUG: Fetching playlist \(playlistId)")
                        do {
                            let playlist = try await SpotifyAPI.fetchPlaylistDetails(
                                accessToken: accessToken,
                                playlistId: playlistId
                            )
                            print("DEBUG: Playlist \(playlistId) fetched: \(playlist.name), tracks: \(playlist.trackCount)")
                            // Only include playlists with at least one track
                            if playlist.trackCount > 0 {
                                print("DEBUG: Playlist \(playlistId) added to list")
                                return playlist
                            } else {
                                print("DEBUG: Playlist \(playlistId) skipped (0 tracks)")
                                return nil
                            }
                        } catch {
                            print("DEBUG: Failed to fetch playlist \(playlistId): \(error)")
                            // Skip playlists that can't be fetched (might be private or deleted)
                            return nil
                        }
                    }
                }

                // Collect all non-nil results
                var results: [SearchPlaylist] = []
                for await playlist in group {
                    if let playlist = playlist {
                        results.append(playlist)
                    }
                }
                return results
            }
            print("DEBUG: Total playlists to display: \(fetchedPlaylists.count)")
            recentPlaylists = fetchedPlaylists

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func extractId(from uri: String) -> String {
        // Extract ID from URI like "spotify:album:xxxxx" or "spotify:playlist:xxxxx"
        let components = uri.split(separator: ":")
        return components.count >= 3 ? String(components[2]) : uri
    }
}
