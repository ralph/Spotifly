//
//  RecentlyPlayedService.swift
//  Spotifly
//
//  Service for recently played content.
//  Fetches data from API and stores entities in AppStore.
//

import Foundation

// Mixed type for recently played albums, artists, and playlists
enum RecentItem: Identifiable, Sendable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)

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
final class RecentlyPlayedService {
    private let store: AppStore

    // Configuration
    private let recentlyPlayedLimit = 30

    // Recent tracks (stored in AppStore, IDs kept here for order)
    private(set) var recentTrackIds: [String] = []

    // Recent items (mixed albums, artists, playlists)
    private(set) var recentItems: [RecentItem] = []

    var isLoading = false
    var errorMessage: String?
    private var hasLoadedInitially = false

    init(store: AppStore) {
        self.store = store
    }

    /// Recent tracks from the store
    var recentTracks: [Track] {
        recentTrackIds.compactMap { store.tracks[$0] }
    }

    // MARK: - Loading

    /// Load recently played (only on first call unless refresh is called)
    func loadRecentlyPlayed(accessToken: String) async {
        guard !hasLoadedInitially else { return }
        hasLoadedInitially = true
        await refresh(accessToken: accessToken)
    }

    /// Force refresh recently played content
    func refresh(accessToken: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchRecentlyPlayed(
                accessToken: accessToken,
                limit: recentlyPlayedLimit,
            )

            // Process tracks - keep all unique tracks
            var uniqueTracks: [String: Track] = [:]
            var orderedTrackIds: [String] = []

            for item in response.items {
                let track = Track(from: item.track)
                if uniqueTracks[track.id] == nil {
                    uniqueTracks[track.id] = track
                    orderedTrackIds.append(track.id)
                }
            }

            // Store tracks in AppStore
            store.upsertTracks(Array(uniqueTracks.values))
            recentTrackIds = orderedTrackIds

            // Process mixed items (albums, artists, playlists) in order of appearance
            var seenIds: Set<String> = []
            var playlistIdsToFetch: [String] = []
            var albumIdsToFetch: [String] = []
            var artistIdsToFetch: [String] = []

            for item in response.items {
                guard let context = item.context else { continue }

                let itemId = extractId(from: context.uri)
                guard !seenIds.contains(itemId) else { continue }
                seenIds.insert(itemId)

                switch context.type {
                case "album":
                    albumIdsToFetch.append(itemId)
                case "artist":
                    artistIdsToFetch.append(itemId)
                case "playlist":
                    playlistIdsToFetch.append(itemId)
                default:
                    break
                }
            }

            // Fetch album details concurrently (return raw API response)
            let fetchedAlbumResponses = await withTaskGroup(of: (id: String, album: SearchAlbum?).self) { group in
                for albumId in albumIdsToFetch {
                    group.addTask {
                        do {
                            let albumDetails = try await SpotifyAPI.fetchAlbumDetails(
                                accessToken: accessToken,
                                albumId: albumId,
                            )
                            return (albumId, albumDetails)
                        } catch {
                            return (albumId, nil)
                        }
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

            // Convert to entities on main actor and store
            var fetchedAlbums: [String: Album] = [:]
            for (id, searchAlbum) in fetchedAlbumResponses {
                let album = Album(from: searchAlbum)
                fetchedAlbums[id] = album
            }
            store.upsertAlbums(Array(fetchedAlbums.values))

            // Fetch playlist details concurrently (return raw API response)
            let fetchedPlaylistResponses = await withTaskGroup(of: (id: String, playlist: SearchPlaylist?).self) { group in
                for playlistId in playlistIdsToFetch {
                    group.addTask {
                        do {
                            let playlistDetails = try await SpotifyAPI.fetchPlaylistDetails(
                                accessToken: accessToken,
                                playlistId: playlistId,
                            )
                            if playlistDetails.trackCount > 0 {
                                return (playlistId, playlistDetails)
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

            // Convert to entities on main actor and store
            var fetchedPlaylists: [String: Playlist] = [:]
            for (id, searchPlaylist) in fetchedPlaylistResponses {
                let playlist = Playlist(from: searchPlaylist)
                fetchedPlaylists[id] = playlist
            }
            store.upsertPlaylists(Array(fetchedPlaylists.values))

            // Fetch artist details concurrently (return raw API response)
            let fetchedArtistResponses = await withTaskGroup(of: (id: String, artist: SearchArtist?).self) { group in
                for artistId in artistIdsToFetch {
                    group.addTask {
                        do {
                            let artistDetails = try await SpotifyAPI.fetchArtistDetails(
                                accessToken: accessToken,
                                artistId: artistId,
                            )
                            return (artistId, artistDetails)
                        } catch {
                            return (artistId, nil)
                        }
                    }
                }

                var results: [String: SearchArtist] = [:]
                for await (id, artist) in group {
                    if let artist {
                        results[id] = artist
                    }
                }
                return results
            }

            // Convert to entities on main actor and store
            var fetchedArtists: [String: Artist] = [:]
            for (id, searchArtist) in fetchedArtistResponses {
                let artist = Artist(from: searchArtist)
                fetchedArtists[id] = artist
            }
            store.upsertArtists(Array(fetchedArtists.values))

            // Build final items list in correct order
            var finalItems: [RecentItem] = []
            var addedIds: Set<String> = []

            for item in response.items {
                guard let context = item.context else { continue }
                let itemId = extractId(from: context.uri)

                guard !addedIds.contains(itemId) else { continue }

                if context.type == "album", let album = fetchedAlbums[itemId] {
                    finalItems.append(.album(album))
                    addedIds.insert(itemId)
                } else if context.type == "playlist", let playlist = fetchedPlaylists[itemId] {
                    finalItems.append(.playlist(playlist))
                    addedIds.insert(itemId)
                } else if context.type == "artist", let artist = fetchedArtists[itemId] {
                    finalItems.append(.artist(artist))
                    addedIds.insert(itemId)
                }
            }

            recentItems = finalItems

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func extractId(from uri: String) -> String {
        let components = uri.split(separator: ":")
        return components.count >= 3 ? String(components[2]) : uri
    }
}
