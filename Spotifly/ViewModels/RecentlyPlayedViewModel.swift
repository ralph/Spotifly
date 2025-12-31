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
            var uniqueAlbums: [String: (uri: String, name: String, artistName: String)] = [:]
            for item in response.items {
                if let context = item.context, context.type == "album" {
                    let albumId = extractId(from: context.uri)
                    if uniqueAlbums[albumId] == nil {
                        uniqueAlbums[albumId] = (
                            uri: context.uri,
                            name: item.track.albumName,
                            artistName: item.track.artistName,
                        )
                    }
                }
            }

            // Convert to SearchAlbum (we'll need to fetch full details later)
            recentAlbums = uniqueAlbums.map { id, info in
                SearchAlbum(
                    id: id,
                    name: info.name,
                    uri: info.uri,
                    artistName: info.artistName,
                    imageURL: nil, // Will be filled when clicked
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
            var uniquePlaylists: [String: String] = [:] // id: uri
            for item in response.items {
                if let context = item.context, context.type == "playlist" {
                    let playlistId = extractId(from: context.uri)
                    if uniquePlaylists[playlistId] == nil {
                        uniquePlaylists[playlistId] = context.uri
                    }
                }
            }

            // For playlists, we'll need to fetch more info later
            // For now, just store minimal info
            recentPlaylists = uniquePlaylists.map { id, uri in
                SearchPlaylist(
                    id: id,
                    name: "Playlist", // Will be updated when needed
                    uri: uri,
                    description: nil,
                    imageURL: nil,
                    trackCount: 0,
                    ownerName: "",
                )
            }

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
