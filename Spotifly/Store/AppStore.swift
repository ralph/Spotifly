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
    var selectedSearchTrack: SearchTrack?
    var selectedSearchAlbum: SearchAlbum?
    var selectedSearchArtist: SearchArtist?
    var selectedSearchPlaylist: SearchPlaylist?
    var showingAllSearchTracks = false
    var expandedSearchAlbums = false
    var expandedSearchArtists = false
    var expandedSearchPlaylists = false
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

    var queueItems: [QueueItem] = []
    var queueErrorMessage: String?

    // MARK: - Device Loading State

    var devicesIsLoading = false
    var devicesErrorMessage: String?

    // MARK: - Spotify Connect State

    var isSpotifyConnectActive = false
    var spotifyConnectDeviceId: String?
    var spotifyConnectDeviceName: String?
    var spotifyConnectVolume: Double = 50

    // Sync task state (stored here so ConnectService instances share it)
    var connectSyncTask: Task<Void, Never>?
    var connectVolumeUpdateTask: Task<Void, Never>?
    var connectConsecutiveSyncFailures = 0

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
        SpotifyPlayer.queueUri(at: currentIndex) ?? currentTrackId
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

    /// Whether to show the Now Playing bar (has queue OR Spotify Connect active)
    var shouldShowNowPlayingBar: Bool {
        queueLength > 0 || isSpotifyConnectActive
    }

    // MARK: - Initialization

    init() {
        setupRemoteCommandCenter()

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

    func selectSearchTrack(_ track: SearchTrack) {
        selectedSearchTrack = track
        selectedSearchAlbum = nil
        selectedSearchArtist = nil
        selectedSearchPlaylist = nil
        showingAllSearchTracks = false
    }

    func selectSearchAlbum(_ album: SearchAlbum) {
        selectedSearchAlbum = album
        selectedSearchTrack = nil
        selectedSearchArtist = nil
        selectedSearchPlaylist = nil
        showingAllSearchTracks = false
    }

    func selectSearchArtist(_ artist: SearchArtist) {
        selectedSearchArtist = artist
        selectedSearchTrack = nil
        selectedSearchAlbum = nil
        selectedSearchPlaylist = nil
        showingAllSearchTracks = false
    }

    func selectSearchPlaylist(_ playlist: SearchPlaylist) {
        selectedSearchPlaylist = playlist
        selectedSearchTrack = nil
        selectedSearchAlbum = nil
        selectedSearchArtist = nil
        showingAllSearchTracks = false
    }

    func showAllSearchTracks() {
        showingAllSearchTracks = true
        selectedSearchTrack = nil
        selectedSearchAlbum = nil
        selectedSearchArtist = nil
        selectedSearchPlaylist = nil
    }

    func clearSearchSelection() {
        selectedSearchTrack = nil
        selectedSearchAlbum = nil
        selectedSearchArtist = nil
        selectedSearchPlaylist = nil
        showingAllSearchTracks = false
    }

    func clearSearch() {
        searchResults = nil
        selectedSearchTrack = nil
        selectedSearchAlbum = nil
        selectedSearchArtist = nil
        selectedSearchPlaylist = nil
        showingAllSearchTracks = false
        expandedSearchAlbums = false
        expandedSearchArtists = false
        expandedSearchPlaylists = false
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

    func setQueueItems(_ items: [QueueItem]) {
        queueItems = items
    }

    // MARK: - Spotify Connect Actions

    /// Activate Spotify Connect mode (playing on remote device)
    func activateSpotifyConnect(deviceId: String, deviceName: String?) {
        isSpotifyConnectActive = true
        spotifyConnectDeviceId = deviceId
        spotifyConnectDeviceName = deviceName

        // Pause local playback when switching to Connect
        if isPlaying {
            SpotifyPlayer.pause()
        }
    }

    /// Deactivate Spotify Connect mode (return to local playback)
    func deactivateSpotifyConnect() {
        isSpotifyConnectActive = false
        spotifyConnectDeviceId = nil
        spotifyConnectDeviceName = nil
    }

    /// Update playback state from Spotify Connect sync
    func updateFromConnectState(_ state: PlaybackState) {
        isPlaying = state.isPlaying
        spotifyConnectVolume = Double(state.device?.volumePercent ?? 50)

        if let track = state.currentTrack {
            currentTrackId = track.uri
            currentTrackName = track.name
            currentArtistName = track.artistName
            currentAlbumArtURL = track.imageURL?.absoluteString
            trackDurationMs = UInt32(track.durationMs)
            currentPositionMs = UInt32(state.progressMs)
            positionAnchorMs = UInt32(state.progressMs)
            positionAnchorTime = CACurrentMediaTime()
            #if DEBUG
                print("[AppStore] updateFromConnectState: position=\(currentPositionMs)ms, duration=\(trackDurationMs)ms, volume=\(spotifyConnectVolume)")
            #endif
            updateNowPlayingInfo()
        }
    }

    // MARK: - Playback Control

    func initializePlayerIfNeeded(accessToken: String) async {
        guard !isPlayerInitialized else { return }

        isLoading = true
        do {
            try await SpotifyPlayer.initialize(accessToken: accessToken)
            isPlayerInitialized = true
            SpotifyPlayer.setVolume(volume)
        } catch {
            playbackError = error.localizedDescription
        }
        isLoading = false
    }

    func play(uriOrUrl: String, accessToken: String) async {
        if !isPlayerInitialized {
            await initializePlayerIfNeeded(accessToken: accessToken)
        }

        guard isPlayerInitialized else {
            playbackError = "Player not initialized"
            return
        }

        isLoading = true
        playbackError = nil

        do {
            try await SpotifyPlayer.play(uriOrUrl: uriOrUrl)
            handlePlaybackStarted(trackId: uriOrUrl)
        } catch {
            playbackError = error.localizedDescription
        }

        isLoading = false
    }

    func playTrack(trackId: String, accessToken: String) async {
        await play(uriOrUrl: "spotify:track:\(trackId)", accessToken: accessToken)
    }

    func playTracks(_ trackUris: [String], accessToken: String) async {
        if !isPlayerInitialized {
            await initializePlayerIfNeeded(accessToken: accessToken)
        }

        guard isPlayerInitialized else {
            playbackError = "Player not initialized"
            return
        }

        guard !trackUris.isEmpty else {
            playbackError = "No tracks to play"
            return
        }

        isLoading = true
        playbackError = nil

        do {
            try await SpotifyPlayer.playTracks(trackUris)
            handlePlaybackStarted(trackId: trackUris[0])
        } catch {
            playbackError = error.localizedDescription
        }

        isLoading = false
    }

    func addToQueue(trackUri: String, accessToken: String) async {
        if !isPlayerInitialized {
            await initializePlayerIfNeeded(accessToken: accessToken)
        }

        guard isPlayerInitialized else {
            playbackError = "Player not initialized"
            return
        }

        playbackError = nil

        do {
            try await SpotifyPlayer.addToQueue(trackUri: trackUri)
            updateQueueState()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func playNext(trackUri: String, accessToken: String) async {
        if !isPlayerInitialized {
            await initializePlayerIfNeeded(accessToken: accessToken)
        }

        guard isPlayerInitialized else {
            playbackError = "Player not initialized"
            return
        }

        playbackError = nil

        do {
            try await SpotifyPlayer.addNextToQueue(trackUri: trackUri)
            updateQueueState()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func togglePlayPause(trackId: String, accessToken: String) async {
        if isPlaying, currentTrackId == trackId {
            SpotifyPlayer.pause()
            isPlaying = false
        } else if !isPlaying, currentTrackId == trackId {
            SpotifyPlayer.resume()
            isPlaying = true
        } else {
            await playTrack(trackId: trackId, accessToken: accessToken)
        }
    }

    func stop() {
        SpotifyPlayer.stop()
        isPlaying = false
        currentTrackId = nil
    }

    func next() {
        do {
            try SpotifyPlayer.next()
            isPlaying = true
            updateQueueState()
            syncPositionAnchor()
            updateNowPlayingInfo()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func previous() {
        do {
            try SpotifyPlayer.previous()
            isPlaying = true
            updateQueueState()
            syncPositionAnchor()
            updateNowPlayingInfo()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func seek(to positionMs: UInt32) {
        do {
            try SpotifyPlayer.seek(positionMs: positionMs)
            positionAnchorMs = positionMs
            positionAnchorTime = CACurrentMediaTime()
            currentPositionMs = positionMs
            updateNowPlayingInfo()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func getQueueTrackName(at index: Int) -> String? {
        SpotifyPlayer.queueTrackName(at: index)
    }

    func getQueueArtistName(at index: Int) -> String? {
        SpotifyPlayer.queueArtistName(at: index)
    }

    // MARK: - Private Playback Helpers

    private func handlePlaybackStarted(trackId: String) {
        currentTrackId = trackId
        isPlaying = true
        SpotifyPlayer.setVolume(volume)
        updateQueueState()
        syncPositionAnchor()
    }

    func updatePlayingState() {
        isPlaying = SpotifyPlayer.isPlaying
    }

    func updateQueueState() {
        queueLength = SpotifyPlayer.queueLength
        currentIndex = SpotifyPlayer.currentIndex

        if queueLength > 0, currentIndex < queueLength {
            currentTrackName = SpotifyPlayer.queueTrackName(at: currentIndex)
            currentArtistName = SpotifyPlayer.queueArtistName(at: currentIndex)
            currentAlbumArtURL = SpotifyPlayer.queueAlbumArtUrl(at: currentIndex)
            trackDurationMs = SpotifyPlayer.queueDurationMs(at: currentIndex)
            updateNowPlayingInfo()
        }
    }

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
        // Skip Rust sync when Spotify Connect is active (sync handled by ConnectService)
        guard !isSpotifyConnectActive else {
            currentPositionMs = interpolatedPositionMs
            updateNowPlayingInfo()
            return
        }

        let rustCurrentIndex = SpotifyPlayer.currentIndex
        if rustCurrentIndex != currentIndex {
            currentIndex = rustCurrentIndex
            isPlaying = SpotifyPlayer.isPlaying
            updateQueueState()
            syncPositionAnchor()
            return
        }

        let rustIsPlaying = SpotifyPlayer.isPlaying
        if rustIsPlaying != isPlaying {
            isPlaying = rustIsPlaying
            syncPositionAnchor()
        }

        currentPositionMs = interpolatedPositionMs

        let rustPosition = SpotifyPlayer.positionMs
        if rustPosition != lastRustPosition {
            let drift = abs(Int32(rustPosition) - Int32(interpolatedPositionMs))
            if drift > 500 {
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

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isPlaying {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying {
                    SpotifyPlayer.pause()
                    self.isPlaying = false
                } else {
                    SpotifyPlayer.resume()
                    self.isPlaying = true
                }
                self.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                guard let seekEvent = event as? MPChangePlaybackPositionCommandEvent else { return }
                let positionMs = UInt32(seekEvent.positionTime * 1000)
                self.seek(to: positionMs)
            }
            return .success
        }
    }
}
