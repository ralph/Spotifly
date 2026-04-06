//
//  AppStore.swift
//  Spotifly
//
//  Central state container with normalized entity storage.
//  Single source of truth for all app data.
//

import Foundation
import SwiftUI

// MARK: - Queue State

/// A track reference in the queue with its provider (normalized - stores ID only, not full metadata)
struct QueueEntry: Equatable {
    let trackId: String
    let provider: TrackProvider
}

/// Normalized queue state storing track entries (ID + provider)
struct Queue {
    /// Previously played tracks (from Mercury only - Web API doesn't provide this)
    var previousTracks: [QueueEntry] = []
    /// Current track
    var currentTrack: QueueEntry?
    /// Next tracks in queue
    var nextTracks: [QueueEntry] = []
    /// Context URI (e.g., "spotify:album:123" or "spotify:playlist:456")
    var contextUri: String?
    /// Whether queue is currently being fetched/updated
    var isLoading = false
    /// Error message if queue fetch failed
    var errorMessage: String?
}

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

    /// Track IDs whose favorite status has been resolved from the Web API
    private(set) var resolvedFavoriteTrackIds: Set<String> = []

    /// User's saved track IDs in display order for the Favorites section (most recent first)
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

    // MARK: - Top Items State

    var topArtistIds: [String] = []
    var topArtistsPagination = PaginationState()
    var topArtistsErrorMessage: String?

    var topTrackAlbumIds: [String] = []
    var topTrackAlbumsPagination = PaginationState()
    var topTrackAlbumsErrorMessage: String?

    // MARK: - Queue State

    /// Queue state (previous/current/next track IDs + loading state)
    var queue = Queue()

    // MARK: - Device Loading State

    var devicesIsLoading = false
    var devicesErrorMessage: String?

    // MARK: - User Profile

    /// Current user's profile (singleton)
    private(set) var userProfile: UserProfile?

    /// Current user's Spotify ID (derived from profile)
    var userId: String? {
        userProfile?.id
    }

    // MARK: - Connection State

    /// Our connection to Spotify (single source of truth for connection info)
    private(set) var connection: SpotifyConnection?

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

    /// Top albums derived from top tracks
    var topTrackAlbums: [Album] {
        topTrackAlbumIds.compactMap { albums[$0] }
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

    /// Current track entity from the tracks store
    var currentTrackEntity: Track? {
        guard let trackId = queue.currentTrack?.trackId else { return nil }
        return tracks[trackId]
    }

    /// Previously played track entities from the tracks store
    var previousTrackEntities: [Track] {
        queue.previousTracks.compactMap { tracks[$0.trackId] }
    }

    /// Next track entities from the tracks store
    var nextTrackEntities: [Track] {
        queue.nextTracks.compactMap { tracks[$0.trackId] }
    }

    /// Total queue length
    var queueLength: Int {
        queue.previousTracks.count + (queue.currentTrack != nil ? 1 : 0) + queue.nextTracks.count
    }

    /// Current track index within the full queue
    var currentIndex: Int {
        queue.previousTracks.count
    }

    /// Active device (if any) - derived from devices dictionary
    var activeDevice: Device? {
        devices.values.first { $0.isActive }
    }

    /// Active device ID - computed from devices (no stored duplication)
    var activeDeviceId: String? {
        activeDevice?.id
    }

    /// Our device ID - computed from connection
    var ownDeviceId: String? {
        connection?.deviceId
    }

    /// Whether we're connected to Spotify
    var isConnected: Bool {
        connection?.isConnected ?? false
    }

    // MARK: - Entity Mutations

    /// Check if a track is favorited
    func isFavorite(_ trackId: String) -> Bool {
        favoriteTrackIds.contains(trackId)
    }

    /// Check if a track's favorite status has already been resolved
    func hasResolvedFavoriteStatus(for trackId: String) -> Bool {
        resolvedFavoriteTrackIds.contains(trackId)
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

    /// Upsert a single album, preserving loaded tracks if present
    func upsertAlbum(_ album: Album) {
        if let existing = albums[album.id], existing.tracksLoaded, !album.tracksLoaded {
            // Preserve existing trackIds and duration when new album doesn't have them
            var merged = album
            merged.trackIds = existing.trackIds
            merged.totalDurationMs = existing.totalDurationMs
            albums[album.id] = merged
        } else {
            albums[album.id] = album
        }
    }

    /// Upsert multiple albums, preserving loaded tracks if present
    func upsertAlbums(_ newAlbums: [Album]) {
        for album in newAlbums {
            upsertAlbum(album)
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

    /// Upsert a single playlist, preserving loaded tracks if present
    func upsertPlaylist(_ playlist: Playlist) {
        if let existing = playlists[playlist.id], existing.tracksLoaded, !playlist.tracksLoaded {
            // Preserve existing trackIds and duration when new playlist doesn't have them
            var merged = playlist
            merged.trackIds = existing.trackIds
            merged.totalDurationMs = existing.totalDurationMs
            playlists[playlist.id] = merged
        } else {
            playlists[playlist.id] = playlist
        }
    }

    /// Upsert multiple playlists, preserving loaded tracks if present
    func upsertPlaylists(_ newPlaylists: [Playlist]) {
        for playlist in newPlaylists {
            upsertPlaylist(playlist)
        }
    }

    /// Upsert devices
    func upsertDevices(_ newDevices: [Device]) {
        let currentActiveId = activeDeviceId
        devices.removeAll()
        for device in newDevices {
            devices[device.id] = device
        }
        // Preserve our tracked active device — HTTP data may lag behind after transfers.
        // On first load (currentActiveId == nil) the HTTP is_active field is used as-is.
        if let currentActiveId, devices[currentActiveId] != nil {
            setActiveDevice(currentActiveId)
        }
    }

    /// Optimistically set a device as active (for immediate UI feedback during transfer)
    /// Creates new Device instances with updated isActive values
    func setActiveDevice(_ deviceId: String) {
        var updatedDevices: [String: Device] = [:]
        for (id, device) in devices {
            let isActive = id == deviceId
            if device.isActive != isActive {
                // Create new Device with updated isActive
                updatedDevices[id] = Device(
                    id: device.id,
                    name: device.name,
                    type: device.type,
                    isActive: isActive,
                    isPrivateSession: device.isPrivateSession,
                    isRestricted: device.isRestricted,
                    volumePercent: device.volumePercent,
                )
            } else {
                updatedDevices[id] = device
            }
        }
        devices = updatedDevices
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

    /// Set saved track IDs for the Favorites section (replaces existing list order only)
    func setSavedTrackIds(_ ids: [String]) {
        savedTrackIds = ids
    }

    /// Append saved track IDs for Favorites pagination
    func appendSavedTrackIds(_ ids: [String]) {
        savedTrackIds.append(contentsOf: ids)
    }

    // MARK: - Favorite Actions

    /// Add track to favorites (optimistic update)
    func addTrackToFavorites(_ trackId: String) {
        favoriteTrackIds.insert(trackId)
        resolvedFavoriteTrackIds.insert(trackId)
        if !savedTrackIds.contains(trackId) {
            savedTrackIds.insert(trackId, at: 0)
        }
    }

    /// Remove track from favorites (optimistic update)
    func removeTrackFromFavorites(_ trackId: String) {
        favoriteTrackIds.remove(trackId)
        resolvedFavoriteTrackIds.insert(trackId)
        savedTrackIds.removeAll { $0 == trackId }
    }

    /// Update favorite status for multiple tracks (from API check)
    func updateFavoriteStatuses(_ statuses: [String: Bool]) {
        for (trackId, isFavorite) in statuses {
            resolvedFavoriteTrackIds.insert(trackId)
            if isFavorite {
                favoriteTrackIds.insert(trackId)
            } else {
                favoriteTrackIds.remove(trackId)
            }
        }
    }

    /// Mark fetched Favorites-section tracks as favorited without changing list order.
    func markTracksAsFavorite(_ trackIds: [String]) {
        let statuses = Dictionary(uniqueKeysWithValues: trackIds.map { ($0, true) })
        updateFavoriteStatuses(statuses)
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

    /// Move track within playlist (reorder)
    func movePlaylistTrack(playlistId: String, fromIndex: Int, toIndex: Int) {
        guard var trackIds = playlists[playlistId]?.trackIds,
              fromIndex >= 0, fromIndex < trackIds.count,
              toIndex >= 0, toIndex < trackIds.count,
              fromIndex != toIndex
        else { return }

        trackIds.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        playlists[playlistId]?.trackIds = trackIds
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

    /// Remove album from user's library
    func removeAlbumFromUserLibrary(_ albumId: String) {
        userAlbumIds.removeAll { $0 == albumId }
    }

    /// Remove artist from user's followed artists
    func removeArtistFromUserLibrary(_ artistId: String) {
        userArtistIds.removeAll { $0 == artistId }
    }

    /// Add album to user's library
    func addAlbumToUserLibrary(_ albumId: String) {
        guard !userAlbumIds.contains(albumId) else { return }
        userAlbumIds.insert(albumId, at: 0)
    }

    /// Add artist to user's followed artists
    func addArtistToUserLibrary(_ artistId: String) {
        guard !userArtistIds.contains(artistId) else { return }
        userArtistIds.insert(artistId, at: 0)
    }

    /// Add playlist to user's library (for followed playlists)
    func addPlaylistToUserLibraryById(_ playlistId: String) {
        guard !userPlaylistIds.contains(playlistId) else { return }
        userPlaylistIds.insert(playlistId, at: 0)
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

    // MARK: - Queue Actions

    /// Set queue state with queue entries. If `previous` is nil, preserves existing (Web API doesn't provide history).
    func setQueue(previous: [QueueEntry]?, current: QueueEntry?, next: [QueueEntry], contextUri: String? = nil) {
        if let previous {
            queue.previousTracks = previous
        }
        queue.currentTrack = current
        queue.nextTracks = next
        // Only update contextUri if provided (non-nil and non-empty)
        if let uri = contextUri, !uri.isEmpty {
            queue.contextUri = uri
        }
    }

    /// Insert a track into the queue after any existing manually queued items (provider: .queue),
    /// but before context tracks. This is used for immediate UI feedback when adding to queue.
    func insertQueuedTrack(trackId: String) {
        let entry = QueueEntry(trackId: trackId, provider: .queue)

        // Find the position to insert: after all existing .queue items, before context items
        let insertIndex = queue.nextTracks.firstIndex { $0.provider != .queue } ?? queue.nextTracks.count
        queue.nextTracks.insert(entry, at: insertIndex)
    }

    /// Set queue loading state
    func setQueueLoading(_ isLoading: Bool) {
        queue.isLoading = isLoading
    }

    /// Set queue error message
    func setQueueError(_ message: String?) {
        queue.errorMessage = message
    }

    // MARK: - User Profile Actions

    /// Set user profile
    func setUserProfile(_ profile: UserProfile?) {
        userProfile = profile
    }

    // MARK: - Connection State Actions

    /// Update connection state
    func setConnection(_ connection: SpotifyConnection?) {
        self.connection = connection
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
                let topArtistsPagination: PaginationState
                let topTrackAlbumIds: [String]
                let topTrackAlbumsPagination: PaginationState

                let queue: QueueSnapshot

                let activeDeviceId: String?

                struct QueueItemSnapshot: Encodable {
                    let trackId: String
                    let provider: String
                }

                struct QueueSnapshot: Encodable {
                    let previousTracks: [QueueItemSnapshot]
                    let currentTrack: QueueItemSnapshot?
                    let nextTracks: [QueueItemSnapshot]
                    let isLoading: Bool
                    let errorMessage: String?
                }

                let connection: SpotifyConnection?
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
                topArtistsPagination: topArtistsPagination,
                topTrackAlbumIds: topTrackAlbumIds,
                topTrackAlbumsPagination: topTrackAlbumsPagination,
                queue: StoreSnapshot.QueueSnapshot(
                    previousTracks: queue.previousTracks.map { StoreSnapshot.QueueItemSnapshot(trackId: $0.trackId, provider: $0.provider.rawValue) },
                    currentTrack: queue.currentTrack.map { StoreSnapshot.QueueItemSnapshot(trackId: $0.trackId, provider: $0.provider.rawValue) },
                    nextTracks: queue.nextTracks.map { StoreSnapshot.QueueItemSnapshot(trackId: $0.trackId, provider: $0.provider.rawValue) },
                    isLoading: queue.isLoading,
                    errorMessage: queue.errorMessage,
                ),
                activeDeviceId: activeDeviceId,
                connection: connection,
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            do {
                let data = try encoder.encode(snapshot)
                if let jsonString = String(data: data, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                    debugLog("Debug", "AppStore state copied to clipboard (\(jsonString.count) chars)")
                }
            } catch {
                debugLog("Debug", "Failed to encode AppStore state: \(error)")
            }
        }
    #endif
}
