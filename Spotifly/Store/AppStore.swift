//
//  AppStore.swift
//  Spotifly
//
//  Central state container with normalized entity storage.
//  Single source of truth for all app data.
//

import Foundation
import MediaPlayer
import QuartzCore
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

// MARK: - Drift Correction Timer

/// Helper class for periodic drift correction (not UI updates)
/// Uses a plain Thread with isCancelled check to avoid Swift concurrency issues
private final class DriftCorrectionTimer {
    private var thread: Thread?
    static let checkNotification = Notification.Name("DriftCorrectionCheck")

    func start() {
        let notificationName = DriftCorrectionTimer.checkNotification
        let thread = Thread {
            while !Thread.current.isCancelled {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: notificationName, object: nil)
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
        thread.name = "com.spotifly.drift-correction"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        thread = nil
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

    // MARK: - Playback State

    var isPlaying = false
    var isLoading = false
    var currentTrackId: String?
    var playbackError: String?
    var queueLength: Int = 0
    var currentIndex: Int = 0

    /// Current track metadata for Now Playing display
    var currentTrackName: String?
    var currentArtistName: String?
    var currentAlbumArtURL: String?
    var trackDurationMs: UInt32 = 0
    var currentPositionMs: UInt32 = 0

    /// Volume (0.0 - 1.0), persisted to UserDefaults
    var volume: Double = 0.5 {
        didSet {
            if isPlayerInitialized {
                SpotifyPlayer.setVolume(volume)
            }
            UserDefaults.standard.set(volume, forKey: "playbackVolume")
        }
    }

    /// Whether current track is favorited (for Now Playing bar)
    var isCurrentTrackFavorited: Bool {
        guard let trackId = extractTrackId(from: currentTrackId) else { return false }
        return favoriteTrackIds.contains(trackId)
    }

    private(set) var isPlayerInitialized = false
    private var lastAlbumArtURL: String?

    // Position tracking
    private var positionAnchorMs: UInt32 = 0
    private var positionAnchorTime: Double = CACurrentMediaTime()
    private var lastRustPosition: UInt32 = 0
    private var driftCorrectionTimer: DriftCorrectionTimer?
    private var driftObserver: NSObjectProtocol?

    // MARK: - Computed Properties (Derived State)

    /// Returns the URI of the currently playing track
    var currentlyPlayingURI: String? {
        currentTrackId
    }

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

    /// Computed position using anchor interpolation - UI should bind to this
    var interpolatedPositionMs: UInt32 {
        guard isPlaying else { return currentPositionMs }
        let elapsed = CACurrentMediaTime() - positionAnchorTime
        let elapsedMs = UInt32(max(0, min(elapsed * 1000, Double(UInt32.max - 1))))
        let interpolated = positionAnchorMs.addingReportingOverflow(elapsedMs).partialValue
        return min(interpolated, trackDurationMs)
    }

    var hasNext: Bool { currentIndex + 1 < queueLength }
    var hasPrevious: Bool { currentIndex > 0 }

    // MARK: - Initialization

    init() {
        // Load saved volume
        let savedVolume = UserDefaults.standard.double(forKey: "playbackVolume")
        if savedVolume > 0 {
            volume = savedVolume
        }

        // Set initial Now Playing info
        var initialInfo: [String: Any] = [:]
        initialInfo[MPMediaItemPropertyTitle] = "Spotifly"
        initialInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = initialInfo

        startPositionTimer()
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

    // MARK: - Playback Control

    func initializePlayerIfNeeded(accessToken: String) async {
        guard !isPlayerInitialized else { return }

        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isPlayerInitialized = true
            SpotifyPlayer.setVolume(volume)

            // Wait for Spirc to be ready (poll with timeout)
            var spirReady = false
            for _ in 0 ..< 50 { // 5 seconds max
                if SpotifyPlayer.isSpircReady {
                    spirReady = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }

            if spirReady {
                // Fetch devices and check if any is active
                let response = try? await SpotifyAPI.fetchAvailableDevices(accessToken: accessToken)
                let hasActiveDevice = response?.devices.contains { $0.isActive } ?? false

                // If no active device, activate ourselves
                if !hasActiveDevice {
                    print("[Spotifly] No active device found, activating local player")
                    try? SpotifyPlayer.transferToLocal()
                }
            }
        } catch {
            playbackError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Private Playback Helpers

    private func syncPositionAnchor() {
        let rustPosition = SpotifyPlayer.positionMs
        positionAnchorMs = rustPosition
        positionAnchorTime = CACurrentMediaTime()
        lastRustPosition = rustPosition
        currentPositionMs = rustPosition
    }

    private func startPositionTimer() {
        let timer = DriftCorrectionTimer()

        driftObserver = NotificationCenter.default.addObserver(
            forName: DriftCorrectionTimer.checkNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkDriftAndSync()
            }
        }

        timer.start()
        driftCorrectionTimer = timer
    }

    private func checkDriftAndSync() {
        // Sync playing state with Rust
        let rustIsPlaying = SpotifyPlayer.isPlaying
        if rustIsPlaying != isPlaying {
            isPlaying = rustIsPlaying
            syncPositionAnchor()
        }

        // Update currentPositionMs for non-TimelineView consumers
        currentPositionMs = interpolatedPositionMs

        // Check for significant drift from Rust position
        let rustPosition = SpotifyPlayer.positionMs
        if rustPosition != lastRustPosition {
            let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
            if drift > 500 {
                // More than 500ms drift - resync anchor
                positionAnchorMs = rustPosition
                positionAnchorTime = CACurrentMediaTime()
                currentPositionMs = min(rustPosition, trackDurationMs)
            }
            lastRustPosition = rustPosition
        }

        updateNowPlayingInfo()
    }

    private func extractTrackId(from uri: String?) -> String? {
        guard let uri else { return nil }
        let components = uri.split(separator: ":")
        guard components.count >= 3, components[0] == "spotify", components[1] == "track" else {
            return nil
        }
        return String(components[2])
    }

    // MARK: - Now Playing Info

    func updateNowPlayingInfo() {
        guard trackDurationMs > 0 else { return }

        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let trackName = currentTrackName {
            nowPlayingInfo[MPMediaItemPropertyTitle] = trackName
        }

        if let artistName = currentArtistName {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artistName
        }

        let validPosition = min(currentPositionMs, trackDurationMs)
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(trackDurationMs) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(validPosition) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        if let artURL = currentAlbumArtURL, artURL != lastAlbumArtURL, !artURL.isEmpty, let url = URL(string: artURL) {
            lastAlbumArtURL = artURL

            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let image = NSImage(data: data) else { return }

                    await MainActor.run {
                        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in
                            image
                        }
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                } catch {
                    // Ignore album art download failures
                }
            }
        }
    }
}
