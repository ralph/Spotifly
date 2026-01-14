//
//  AppStore.swift
//  Spotifly
//
//  Central state container with normalized entity storage.
//  Single source of truth for all app data.
//

import Foundation
import SwiftUI

// MARK: - Recent Item

/// Mixed type for recently played albums, artists, and playlists
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

    var isArtist: Bool {
        if case .artist = self { return true }
        return false
    }
}

// MARK: - App Store

@MainActor
@Observable
final class AppStore {
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
    private(set) var recentItems: [RecentItem] = []
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

    // MARK: - Queue State

    /// Queue track URIs from Mercury (source of truth for queue order)
    private(set) var queueURIs: [String] = []
    /// Queue items with full metadata (derived from queueURIs + tracks store)
    var queueItems: [QueueItem] = []
    var queueErrorMessage: String?

    // MARK: - Device Loading State

    var devicesIsLoading = false
    var devicesErrorMessage: String?
    var activeDeviceId: String? // Tracks which device is currently active

    // MARK: - Playback State (used by QueueService and UI)

    var currentTrackId: String?
    var queueLength: Int = 0
    var currentIndex: Int = 0

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

    func setRecentItems(_ items: [RecentItem]) {
        recentItems = items
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

    func setQueueURIs(_ uris: [String]) {
        queueURIs = uris
    }

    func setQueueItems(_ items: [QueueItem]) {
        queueItems = items
        queueLength = items.count
    }
}
