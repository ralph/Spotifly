//
//  RecentlyPlayedViewModel.swift
//  Spotifly
//
//  Manages recently played content
//

import SwiftUI

// Mixed type for recently played albums, artists, and playlists
enum RecentItem: Identifiable {
    case album(SearchAlbum)
    case artist(SearchArtist)
    case playlist(SearchPlaylist)

    var id: String {
        switch self {
        case let .album(album): "album_\(album.id)"
        case let .artist(artist): "artist_\(artist.id)"
        case let .playlist(playlist): "playlist_\(playlist.id)"
        }
    }
}

@MainActor
@Observable
final class RecentlyPlayedViewModel {
    // Configuration
    private let recentlyPlayedLimit = 30 // Easy to adjust for experimentation

    var recentTracks: [SearchTrack] = []
    var recentItems: [RecentItem] = [] // Mixed albums, artists, playlists
    var isLoading = false
    var errorMessage: String?
    private var hasLoadedInitially = false

    func loadRecentlyPlayed(accessToken: String) async {
        // Only load automatically on first call
        guard !hasLoadedInitially else { return }
        hasLoadedInitially = true
        await refresh(accessToken: accessToken)
    }

    func refresh(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchRecentlyPlayed(accessToken: accessToken, limit: recentlyPlayedLimit)

            // Process tracks - keep all unique tracks
            var uniqueTracks: [String: SearchTrack] = [:]
            for item in response.items {
                if uniqueTracks[item.track.id] == nil {
                    uniqueTracks[item.track.id] = item.track
                }
            }
            recentTracks = Array(uniqueTracks.values)

            // Process mixed items (albums, artists, playlists) in order of appearance
            var seenIds: Set<String> = []
            var mixedItems: [RecentItem] = []
            var playlistIdsToFetch: [String] = []
            var albumIdsToFetch: [String] = []

            for item in response.items {
                guard let context = item.context else { continue }

                let itemId = extractId(from: context.uri)
                guard !seenIds.contains(itemId) else { continue }
                seenIds.insert(itemId)

                switch context.type {
                case "album":
                    albumIdsToFetch.append(itemId)

                case "artist":
                    let artist = SearchArtist(
                        id: itemId,
                        name: item.track.artistName,
                        uri: context.uri,
                        imageURL: nil,
                        genres: [],
                        followers: 0,
                    )
                    mixedItems.append(.artist(artist))

                case "playlist":
                    playlistIdsToFetch.append(itemId)

                default:
                    break
                }
            }

            // Fetch album details concurrently
            let fetchedAlbums = await withTaskGroup(of: (id: String, album: SearchAlbum?).self) { group in
                for albumId in albumIdsToFetch {
                    group.addTask {
                        do {
                            let albumDetails = try await SpotifyAPI.fetchAlbumDetails(
                                accessToken: accessToken,
                                albumId: albumId,
                            )
                            return (albumId, albumDetails)
                        } catch {
                            // Skip albums that can't be fetched
                        }
                        return (albumId, nil)
                    }
                }

                var results: [String: SearchAlbum] = [:]
                for await (id, album) in group {
                    if let album {
                        results[id] = album
                    }
                }
                return results
            }

            // Fetch playlist details concurrently
            let fetchedPlaylists = await withTaskGroup(of: (id: String, playlist: SearchPlaylist?).self) { group in
                for playlistId in playlistIdsToFetch {
                    group.addTask {
                        do {
                            let playlist = try await SpotifyAPI.fetchPlaylistDetails(
                                accessToken: accessToken,
                                playlistId: playlistId,
                            )
                            if playlist.trackCount > 0 {
                                return (playlistId, playlist)
                            }
                        } catch {
                            // Skip playlists that can't be fetched
                        }
                        return (playlistId, nil)
                    }
                }

                var results: [String: SearchPlaylist] = [:]
                for await (id, playlist) in group {
                    if let playlist {
                        results[id] = playlist
                    }
                }
                return results
            }

            // Insert albums, playlists, and artists in the correct order
            var finalItems: [RecentItem] = []

            for item in response.items {
                guard let context = item.context else { continue }
                let itemId = extractId(from: context.uri)

                if context.type == "album", let album = fetchedAlbums[itemId] {
                    // Check if we've already added this album
                    let alreadyAdded = finalItems.contains { recentItem in
                        if case let .album(a) = recentItem, a.id == album.id {
                            return true
                        }
                        return false
                    }

                    if !alreadyAdded {
                        finalItems.append(.album(album))
                    }
                } else if context.type == "playlist", let playlist = fetchedPlaylists[itemId] {
                    // Check if we've already added this playlist
                    let alreadyAdded = finalItems.contains { recentItem in
                        if case let .playlist(p) = recentItem, p.id == playlist.id {
                            return true
                        }
                        return false
                    }

                    if !alreadyAdded {
                        finalItems.append(.playlist(playlist))
                    }
                } else if context.type == "artist" {
                    // Add artist if not already added
                    let matchingItem = mixedItems.first { recentItem in
                        if case let .artist(artist) = recentItem, artist.id == itemId {
                            return true
                        }
                        return false
                    }

                    if let matchingItem {
                        let alreadyAdded = finalItems.contains { $0.id == matchingItem.id }
                        if !alreadyAdded {
                            finalItems.append(matchingItem)
                        }
                    }
                }
            }

            recentItems = finalItems

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
