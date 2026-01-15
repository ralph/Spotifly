//
//  AppStore.swift
//  Spotifly
//
//  Central state container with normalized entity storage.
//  Single source of truth for all app data.
//

import Foundation
import SwiftUI

// MARK: - App Store

@MainActor
@Observable
final class AppStore {
    #if DEBUG
        /// Debug-only reference for menu commands
        weak static var current: AppStore?
    #endif

    // MARK: - Entity Tables (Normalized)

    /// All tracks indexed by ID - single source of truth
    private(set) var tracks: [String: Track] = [:]

    /// All albums indexed by ID
    private(set) var albums: [String: Album] = [:]

    /// All artists indexed by ID
    private(set) var artists: [String: Artist] = [:]

    /// All playlists indexed by ID
    private(set) var playlists: [String: Playlist] = [:]

    /// All devices indexed by ID
    private(set) var devices: [String: Device] = [:]

    // MARK: - User Library State (IDs only)

    /// User's playlist IDs in display order
    private(set) var userPlaylistIds: [String] = []

    /// User's saved album IDs in display order
    private(set) var userAlbumIds: [String] = []

    /// User's followed artist IDs in display order
    private(set) var userArtistIds: [String] = []

    /// User's favorite track IDs (Set for O(1) lookup)
    private(set) var favoriteTrackIds: Set<String> = []

    /// User's saved track IDs in display order (most recent first)
    private(set) var savedTrackIds: [String] = []

    // MARK: - Pagination State

    var playlistsPagination = PaginationState()
    var albumsPagination = PaginationState()
    var artistsPagination = PaginationState()
    var favoritesPagination = PaginationState()

    // MARK: - Search State

    var searchResults: SearchResults?
    var searchIsLoading = false
    var searchErrorMessage: String?

    // MARK: - Recently Played State

    private(set) var recentTrackIds: [String] = []
    /// URIs of recent albums/artists/playlists (e.g., "spotify:album:123")
    private(set) var recentItemURIs: [String] = []
    var recentlyPlayedIsLoading = false
    var recentlyPlayedErrorMessage: String?
    var hasLoadedRecentlyPlayed = false

    // MARK: - Top Artists State

    private(set) var topArtistIds: [String] = []
    var topArtistsIsLoading = false
    var topArtistsErrorMessage: String?
    var hasLoadedTopArtists = false

    // MARK: - New Releases State

    private(set) var newReleaseAlbumIds: [String] = []
    var newReleasesIsLoading = false
    var newReleasesErrorMessage: String?
    var hasLoadedNewReleases = false

    // MARK: - Queue State (matches Spotify's prev/current/next structure)

    /// Current track URI (from Mercury or Web API)
    private(set) var currentTrackURI: String?
    /// Previously played track URIs (from Mercury only - Web API doesn't provide this)
    private(set) var previousTrackURIs: [String] = []
    /// Next track URIs (from Mercury or Web API)
    private(set) var nextTrackURIs: [String] = []
    var queueErrorMessage: String?

    // MARK: - Device Loading State

    var devicesIsLoading = false
    var devicesErrorMessage: String?
    var activeDeviceId: String? // Tracks which device is currently active

    // MARK: - Computed Properties (Derived State)

    /// User's playlists in display order
    var userPlaylists: [Playlist] {
        userPlaylistIds.compactMap { playlists[$0] }
    }

    /// User's saved albums in display order
    var userAlbums: [Album] {
        userAlbumIds.compactMap { albums[$0] }
    }

    /// User's followed artists in display order
    var userArtists: [Artist] {
        userArtistIds.compactMap { artists[$0] }
    }

    /// User's favorite tracks in display order
    var favoriteTracks: [Track] {
        savedTrackIds.compactMap { tracks[$0] }
    }

    /// Available Spotify devices
    var availableDevices: [Device] {
        Array(devices.values)
    }

    /// Recent tracks from the store
    var recentTracks: [Track] {
        recentTrackIds.compactMap { tracks[$0] }
    }

    /// Top artists from the store
    var topArtists: [Artist] {
        topArtistIds.compactMap { artists[$0] }
    }

    /// New release albums from the store
    var newReleaseAlbums: [Album] {
        newReleaseAlbumIds.compactMap { albums[$0] }
    }

    /// Recent albums and playlists (excludes artists) from URIs
    var recentAlbumsAndPlaylists: [(id: String, album: Album?, playlist: Playlist?)] {
        recentItemURIs.compactMap { uri -> (id: String, album: Album?, playlist: Playlist?)? in
            if uri.hasPrefix("spotify:album:") {
                let id = String(uri.dropFirst("spotify:album:".count))
                guard let album = albums[id] else { return nil }
                return (id: uri, album: album, playlist: nil)
            } else if uri.hasPrefix("spotify:playlist:") {
                let id = String(uri.dropFirst("spotify:playlist:".count))
                guard let playlist = playlists[id] else { return nil }
                return (id: uri, album: nil, playlist: playlist)
            }
            // Skip artists
            return nil
        }
    }

    // MARK: - Queue Computed Properties

    /// Current track from the tracks store
    var currentTrack: Track? {
        guard let uri = currentTrackURI,
              let id = SpotifyAPI.parseTrackURI(uri) else { return nil }
        return tracks[id]
    }

    /// Previously played tracks from the tracks store
    var previousTracks: [Track] {
        previousTrackURIs.compactMap { uri in
            guard let id = SpotifyAPI.parseTrackURI(uri) else { return nil }
            return tracks[id]
        }
    }

    /// Next tracks from the tracks store
    var nextTracks: [Track] {
        nextTrackURIs.compactMap { uri in
            guard let id = SpotifyAPI.parseTrackURI(uri) else { return nil }
            return tracks[id]
        }
    }

    /// Total queue length
    var queueLength: Int {
        previousTrackURIs.count + (currentTrackURI != nil ? 1 : 0) + nextTrackURIs.count
    }

    /// Current track index within the full queue
    var currentIndex: Int {
        previousTrackURIs.count
    }

    /// Active device (if any)
    var activeDevice: Device? {
        devices.values.first { $0.isActive }
    }

    // MARK: - Entity Mutations

    /// Check if a track is favorited
    func isFavorite(_ trackId: String) -> Bool {
        favoriteTrackIds.contains(trackId)
    }

    /// Upsert a single track
    func upsertTrack(_ track: Track) {
        tracks[track.id] = track
    }

    /// Upsert multiple tracks
    func upsertTracks(_ newTracks: [Track]) {
        for track in newTracks {
            tracks[track.id] = track
        }
    }

    /// Upsert a single album
    func upsertAlbum(_ album: Album) {
        albums[album.id] = album
    }

    /// Upsert multiple albums
    func upsertAlbums(_ newAlbums: [Album]) {
        for album in newAlbums {
            albums[album.id] = album
        }
    }

    /// Upsert a single artist
    func upsertArtist(_ artist: Artist) {
        artists[artist.id] = artist
    }

    /// Upsert multiple artists
    func upsertArtists(_ newArtists: [Artist]) {
        for artist in newArtists {
            artists[artist.id] = artist
        }
    }

    /// Upsert a single playlist
    func upsertPlaylist(_ playlist: Playlist) {
        playlists[playlist.id] = playlist
    }

    /// Upsert multiple playlists
    func upsertPlaylists(_ newPlaylists: [Playlist]) {
        for playlist in newPlaylists {
            playlists[playlist.id] = playlist
        }
    }

    /// Upsert devices
    func upsertDevices(_ newDevices: [Device]) {
        devices.removeAll()
        for device in newDevices {
            devices[device.id] = device
        }
    }

    // MARK: - User Library Mutations

    /// Set user's playlist IDs (replaces existing)
    func setUserPlaylistIds(_ ids: [String]) {
        userPlaylistIds = ids
    }

    /// Append playlist IDs (for pagination)
    func appendUserPlaylistIds(_ ids: [String]) {
        userPlaylistIds.append(contentsOf: ids)
    }

    /// Set user's album IDs (replaces existing)
    func setUserAlbumIds(_ ids: [String]) {
        userAlbumIds = ids
    }

    /// Append album IDs (for pagination)
    func appendUserAlbumIds(_ ids: [String]) {
        userAlbumIds.append(contentsOf: ids)
    }

    /// Set user's artist IDs (replaces existing)
    func setUserArtistIds(_ ids: [String]) {
        userArtistIds = ids
    }

    /// Append artist IDs (for pagination)
    func appendUserArtistIds(_ ids: [String]) {
        userArtistIds.append(contentsOf: ids)
    }

    /// Set saved track IDs (replaces existing)
    func setSavedTrackIds(_ ids: [String]) {
        savedTrackIds = ids
        favoriteTrackIds = Set(ids)
    }

    /// Append saved track IDs (for pagination)
    func appendSavedTrackIds(_ ids: [String]) {
        savedTrackIds.append(contentsOf: ids)
        favoriteTrackIds.formUnion(ids)
    }

    // MARK: - Favorite Actions

    /// Add track to favorites (optimistic update)
    func addTrackToFavorites(_ trackId: String) {
        favoriteTrackIds.insert(trackId)
        if !savedTrackIds.contains(trackId) {
            savedTrackIds.insert(trackId, at: 0)
        }
    }

    /// Remove track from favorites (optimistic update)
    func removeTrackFromFavorites(_ trackId: String) {
        favoriteTrackIds.remove(trackId)
        savedTrackIds.removeAll { $0 == trackId }
    }

    /// Update favorite status for multiple tracks (from API check)
    func updateFavoriteStatuses(_ statuses: [String: Bool]) {
        for (trackId, isFavorite) in statuses {
            if isFavorite {
                favoriteTrackIds.insert(trackId)
            } else {
                favoriteTrackIds.remove(trackId)
            }
        }
    }

    // MARK: - Playlist Actions

    /// Add track to playlist
    func addTrackToPlaylist(_ trackId: String, playlistId: String) {
        playlists[playlistId]?.trackIds.append(trackId)
        // Recalculate duration if we have the track
        if let track = tracks[trackId] {
            let currentDuration = playlists[playlistId]?.totalDurationMs ?? 0
            playlists[playlistId]?.totalDurationMs = currentDuration + track.durationMs
        }
    }

    /// Remove track from playlist
    func removeTrackFromPlaylist(_ trackId: String, playlistId: String) {
        if let track = tracks[trackId], let currentDuration = playlists[playlistId]?.totalDurationMs {
            playlists[playlistId]?.totalDurationMs = max(0, currentDuration - track.durationMs)
        }
        playlists[playlistId]?.trackIds.removeAll { $0 == trackId }
    }

    /// Update playlist details
    func updatePlaylistDetails(id: String, name: String? = nil, description: String? = nil, isPublic: Bool? = nil) {
        if let name { playlists[id]?.name = name }
        if let description { playlists[id]?.description = description }
        if let isPublic { playlists[id]?.isPublic = isPublic }
    }

    /// Add a new playlist to user's library
    func addPlaylistToUserLibrary(_ playlist: Playlist) {
        playlists[playlist.id] = playlist
        userPlaylistIds.insert(playlist.id, at: 0)
    }

    /// Remove playlist from user's library
    func removePlaylistFromUserLibrary(_ playlistId: String) {
        userPlaylistIds.removeAll { $0 == playlistId }
        playlists.removeValue(forKey: playlistId)
    }

    // MARK: - Search Actions

    func setSearchResults(_ results: SearchResults?) {
        searchResults = results
    }

    func clearSearch() {
        searchResults = nil
        searchErrorMessage = nil
    }

    // MARK: - Recently Played Actions

    func setRecentTrackIds(_ ids: [String]) {
        recentTrackIds = ids
    }

    func setRecentItemURIs(_ uris: [String]) {
        recentItemURIs = uris
    }

    // MARK: - Top Items Actions

    func setTopArtistIds(_ ids: [String]) {
        topArtistIds = ids
    }

    // MARK: - New Releases Actions

    func setNewReleaseAlbumIds(_ ids: [String]) {
        newReleaseAlbumIds = ids
    }

    // MARK: - Queue Actions

    /// Set queue state. If `previous` is nil, preserves existing previousTrackURIs (Web API case).
    func setQueue(previous: [String]?, current: String?, next: [String]) {
        if let previous {
            previousTrackURIs = previous
        }
        currentTrackURI = current
        nextTrackURIs = next
    }

    // MARK: - Debug

    #if DEBUG
        /// Dumps the entire store state as pretty-printed JSON to the console
        func debugDumpJSON() {
            struct StoreSnapshot: Encodable {
                let tracks: [String: Track]
                let albums: [String: Album]
                let artists: [String: Artist]
                let playlists: [String: Playlist]
                let devices: [String: Device]

                let userPlaylistIds: [String]
                let userAlbumIds: [String]
                let userArtistIds: [String]
                let favoriteTrackIds: [String]
                let savedTrackIds: [String]

                let playlistsPagination: PaginationState
                let albumsPagination: PaginationState
                let artistsPagination: PaginationState
                let favoritesPagination: PaginationState

                let searchResults: SearchResults?

                let recentTrackIds: [String]
                let recentItemURIs: [String]

                let topArtistIds: [String]
                let newReleaseAlbumIds: [String]

                let currentTrackURI: String?
                let previousTrackURIs: [String]
                let nextTrackURIs: [String]

                let activeDeviceId: String?
            }

            let snapshot = StoreSnapshot(
                tracks: tracks,
                albums: albums,
                artists: artists,
                playlists: playlists,
                devices: devices,
                userPlaylistIds: userPlaylistIds,
                userAlbumIds: userAlbumIds,
                userArtistIds: userArtistIds,
                favoriteTrackIds: Array(favoriteTrackIds),
                savedTrackIds: savedTrackIds,
                playlistsPagination: playlistsPagination,
                albumsPagination: albumsPagination,
                artistsPagination: artistsPagination,
                favoritesPagination: favoritesPagination,
                searchResults: searchResults,
                recentTrackIds: recentTrackIds,
                recentItemURIs: recentItemURIs,
                topArtistIds: topArtistIds,
                newReleaseAlbumIds: newReleaseAlbumIds,
                currentTrackURI: currentTrackURI,
                previousTrackURIs: previousTrackURIs,
                nextTrackURIs: nextTrackURIs,
                activeDeviceId: activeDeviceId,
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            do {
                let data = try encoder.encode(snapshot)
                if let jsonString = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                    print("[Debug] AppStore state copied to clipboard (\(jsonString.count) chars)")
                }
            } catch {
                print("[Debug] Failed to encode AppStore state: \(error)")
            }
        }
    #endif
}
