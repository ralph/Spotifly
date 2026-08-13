//
//  RecentlyPlayedService.swift
//  Spotifly
//
//  Service for recently played content.
//  Fetches data from API and stores entities in AppStore.
//

import Foundation

@MainActor
@Observable
final class RecentlyPlayedService {
    private let store: AppStore

    /// Configuration
    private let recentlyPlayedLimit = 30

    /// Album reads run on the keymaster grant through `PartnerAPI`, which holds that token
    /// itself; the rest of this service is still on the Web API token passed in per call.
    private let partnerAPI: PartnerAPI

    init(store: AppStore, partnerAPI: PartnerAPI = PartnerAPI()) {
        self.store = store
        self.partnerAPI = partnerAPI
    }

    // MARK: - Loading

    /// In-flight recently-played load. Stored so concurrent callers await the same
    /// load instead of starting a new one, and — because it's an unstructured Task —
    /// so the load survives cancellation of the caller's `.task`. Mirrors the
    /// library services (AlbumService/ArtistService/PlaylistService/TrackService).
    private var loadTask: Task<Void, Never>?

    /// Load recently played (only on first call unless forceRefresh is true)
    func loadRecentlyPlayed(accessToken: String, forceRefresh: Bool = false) async {
        if !forceRefresh, store.hasLoadedRecentlyPlayed {
            return
        }

        // Force refresh cancels any in-flight load and starts over
        if forceRefresh {
            loadTask?.cancel()
            loadTask = nil
        }

        // If a load is already in flight, await it instead of starting a new one.
        if let existingTask = loadTask {
            await existingTask.value
            return
        }

        store.recentlyPlayedIsLoading = true
        store.recentlyPlayedErrorMessage = nil

        let task = Task {
            defer {
                self.loadTask = nil
                self.store.recentlyPlayedIsLoading = false
            }
            await self.performLoad(accessToken: accessToken)
        }
        loadTask = task
        await task.value
    }

    /// Force refresh recently played content
    func refresh(accessToken: String) async {
        await loadRecentlyPlayed(accessToken: accessToken, forceRefresh: true)
    }

    private func performLoad(accessToken: String) async {
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
            store.setRecentTrackIds(orderedTrackIds)

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

            // Fetch album details concurrently. `getAlbum` answers with the album's tracks
            // beside it, which this strip does not need but also does not pay for twice —
            // storing them means opening one of these albums needs no request at all.
            let partnerAPI = partnerAPI
            let fetchedAlbumResponses = await withTaskGroup(of: (id: String, album: PathfinderAlbumUnion?).self) { group in
                for albumId in albumIdsToFetch {
                    group.addTask {
                        do {
                            return try await (albumId, partnerAPI.album(id: albumId))
                        } catch {
                            return (albumId, nil)
                        }
                    }
                }

                var results: [String: PathfinderAlbumUnion] = [:]
                for await (id, album) in group {
                    if let album {
                        results[id] = album
                    }
                }
                return results
            }

            // Convert to entities on main actor and store
            var fetchedAlbums: [String: Album] = [:]
            for (id, union) in fetchedAlbumResponses {
                guard let (album, tracks) = union.entities() else { continue }

                fetchedAlbums[id] = album
                store.upsertTracks(tracks)
            }
            store.upsertAlbums(Array(fetchedAlbums.values))

            // Fetch playlist details concurrently (return raw API response)
            let fetchedPlaylistResponses = await withTaskGroup(of: (id: String, playlist: APIPlaylist?).self) { group in
                for playlistId in playlistIdsToFetch {
                    group.addTask {
                        do {
                            let playlistDetails = try await SpotifyAPI.fetchPlaylistDetails(
                                accessToken: accessToken,
                                playlistId: playlistId,
                            )
                            return (playlistId, playlistDetails)
                        } catch {
                            // Skip playlists that can't be fetched
                        }
                        return (playlistId, nil)
                    }
                }

                var results: [String: APIPlaylist] = [:]
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
            let fetchedArtistResponses = await withTaskGroup(of: (id: String, artist: APIArtist?).self) { group in
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

                var results: [String: APIArtist] = [:]
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

            // Build final URIs list in correct order (entities already upserted to stores above)
            var finalURIs: [String] = []
            var addedIds: Set<String> = []

            for item in response.items {
                guard let context = item.context else { continue }
                let itemId = extractId(from: context.uri)

                guard !addedIds.contains(itemId) else { continue }

                // Only add URI if entity was successfully fetched
                if context.type == "album", fetchedAlbums[itemId] != nil {
                    finalURIs.append(context.uri)
                    addedIds.insert(itemId)
                } else if context.type == "playlist", fetchedPlaylists[itemId] != nil {
                    finalURIs.append(context.uri)
                    addedIds.insert(itemId)
                } else if context.type == "artist", fetchedArtists[itemId] != nil {
                    finalURIs.append(context.uri)
                    addedIds.insert(itemId)
                }
            }

            store.setRecentItemURIs(finalURIs)

            // Mark as loaded only after successful completion
            store.hasLoadedRecentlyPlayed = true

        } catch {
            store.recentlyPlayedErrorMessage = error.localizedDescription
        }
    }

    private func extractId(from uri: String) -> String {
        let components = uri.split(separator: ":")
        return components.count >= 3 ? String(components[2]) : uri
    }
}
