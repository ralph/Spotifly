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
struct Queue: Equatable {
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

    /// Returns the same queue ordering, split around the occurrence of `trackId` nearest
    /// the currently reported split. librespot can report a stale split while its ordering
    /// is already correct, so the playing track's logical identity is authoritative.
    func reconciled(currentTrackId trackId: String) -> Queue {
        let allTracks = previousTracks + (currentTrack.map { [$0] } ?? []) + nextTracks
        let reportedIndex = previousTracks.count
        let matchingIndices = allTracks.indices.filter { allTracks[$0].trackId == trackId }

        guard let currentIndex = matchingIndices.min(by: { lhs, rhs in
            let lhsDistance = abs(lhs - reportedIndex)
            let rhsDistance = abs(rhs - reportedIndex)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }) else {
            return self
        }

        var result = self
        result.previousTracks = Array(allTracks[..<currentIndex])
        result.currentTrack = allTracks[currentIndex]
        result.nextTracks = Array(allTracks[(currentIndex + 1)...])
        return result
    }
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

    /// Album IDs per artist, in the order the API returned them. Cached like album
    /// and playlist tracks are, so an artist's discography is fetched once instead
    /// of on every visit to their page.
    private(set) var artistAlbumIds: [String: [String]] = [:]

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

    static let searchResultsLimit = 5

    private(set) var searchResultsByQuery: [String: SearchResults] = [:]
    /// Oldest to newest, used to enforce the bounded query cache.
    private(set) var searchResultQueries: [String] = []
    private(set) var lastDisplayedSearchQuery: String?
    private(set) var searchCacheEvictionRevision: UInt64 = 0
    var searchIsLoading = false
    var searchErrorMessage: String?

    /// Entities explicitly deleted during this session. Missing entities are not
    /// enough to invalidate a route because a deep-linked entity may still be loading.
    private(set) var deletedEntitySelections: Set<Selection> = []

    // MARK: - Start Page State

    /// Spotify's own start page, as shelves of ids. One request fills all of it, so there is a
    /// single loading flag and a single error rather than one per section.
    private(set) var homeSections: [HomeSection] = []
    private(set) var homeGreeting: String?
    var homeIsLoading = false
    var homeErrorMessage: String?
    var hasLoadedHome = false

    // MARK: - Queue State

    /// Queue state (previous/current/next track IDs + loading state)
    var queue = Queue()

    // MARK: - Device Loading State

    /// True until the first cluster update arrives. Not a request in flight — the device list
    /// is pushed, so there is nothing to fail and no error to show; there is only "not yet".
    var devicesIsLoading = false

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

    /// Upsert a single album. What we already know is never downgraded: a stub
    /// entity (the one the start page builds out of a shelf entry, which carries no
    /// release date or album type) does not replace fully fetched metadata, and no
    /// upsert drops loaded tracks.
    func upsertAlbum(_ album: Album) {
        deletedEntitySelections.remove(.album(id: album.id))
        guard let existing = albums[album.id] else {
            albums[album.id] = album
            return
        }
        guard album.detailsLoaded || !existing.detailsLoaded else { return }

        var merged = album
        if existing.tracksLoaded, !merged.tracksLoaded {
            merged.trackIds = existing.trackIds
            merged.totalDurationMs = existing.totalDurationMs
            merged.tracksLoaded = true
        }
        albums[album.id] = merged
    }

    /// Attach a fetched track list to an album. Marks it loaded even when the album
    /// has no tracks, so it is not fetched again on the next visit.
    func setAlbumTracks(_ trackIds: [String], totalDurationMs: Int?, for albumId: String) {
        guard var album = albums[albumId] else { return }
        album.trackIds = trackIds
        album.totalDurationMs = totalDurationMs
        album.tracksLoaded = true
        albums[albumId] = album
    }

    /// Upsert multiple albums, preserving loaded tracks if present
    func upsertAlbums(_ newAlbums: [Album]) {
        for album in newAlbums {
            upsertAlbum(album)
        }
    }

    /// Upsert a single artist
    func upsertArtist(_ artist: Artist) {
        deletedEntitySelections.remove(.artist(id: artist.id))
        artists[artist.id] = artist
    }

    /// Upsert multiple artists
    func upsertArtists(_ newArtists: [Artist]) {
        for artist in newArtists {
            artists[artist.id] = artist
        }
    }

    /// Record an artist's fetched album list. The albums themselves go through
    /// `upsertAlbums`; this only stores the order.
    func setArtistAlbums(_ albumIds: [String], for artistId: String) {
        artistAlbumIds[artistId] = albumIds
    }

    /// An artist's albums in display order, or nil if they have not been fetched.
    func albums(forArtist artistId: String) -> [Album]? {
        artistAlbumIds[artistId]?.compactMap { albums[$0] }
    }

    /// Upsert a single playlist, preserving loaded tracks if present
    func upsertPlaylist(_ playlist: Playlist) {
        deletedEntitySelections.remove(.playlist(id: playlist.id))
        if let existing = playlists[playlist.id], existing.tracksLoaded, !playlist.tracksLoaded {
            // Preserve existing items and duration when new playlist doesn't have them
            var merged = playlist
            merged.items = existing.items
            merged.totalDurationMs = existing.totalDurationMs
            merged.tracksLoaded = true
            playlists[playlist.id] = merged
        } else {
            playlists[playlist.id] = playlist
        }
    }

    /// Attach a fetched track list to a playlist. Marks it loaded even when the
    /// playlist is empty, so it is not fetched again on the next visit.
    func setPlaylistTracks(_ items: [PlaylistItem], totalDurationMs: Int?, for playlistId: String) {
        guard var playlist = playlists[playlistId] else { return }
        playlist.items = items
        playlist.totalDurationMs = totalDurationMs
        playlist.tracksLoaded = true
        playlists[playlistId] = playlist
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
        savedTrackIds = Self.deduplicated(ids)
    }

    /// Append saved track IDs for Favorites pagination
    func appendSavedTrackIds(_ ids: [String]) {
        savedTrackIds = Self.deduplicated(savedTrackIds + ids)
    }

    /// Relinking is **many-to-one**: several saved recordings can share one market id, which is
    /// the id the app keys tracks by (`AGENTS.md`, "Track identity is the market id"). So a
    /// library page can name the same track twice, and two pages can each name it once.
    ///
    /// One row per track is not cosmetic here. `favoriteTracks` feeds a SwiftUI `ForEach` keyed
    /// by `Track.id`, and duplicate ids there are undefined behaviour rather than a duplicate
    /// row. Deduplicating across the whole list rather than per page is what makes the second
    /// case work.
    ///
    /// A knock-on worth knowing: the list can be shorter than the `total` Spotify reports,
    /// because that counts saved entries and this counts tracks. Pagination is unaffected —
    /// offsets are Spotify's side of the conversation.
    private static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
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
    ///
    /// Tolerates a repeated id rather than trapping on one: a library page can name the same
    /// market recording twice, for the reason `deduplicated` explains. The status is the same
    /// `true` either way, so collapsing them loses nothing.
    func markTracksAsFavorite(_ trackIds: [String]) {
        let statuses = Dictionary(trackIds.map { ($0, true) }, uniquingKeysWith: { first, _ in first })
        updateFavoriteStatuses(statuses)
    }

    // MARK: - Playlist Actions

    /// Add a track to a playlist optimistically.
    ///
    /// The uid is Spotify's to assign, and the response does not carry it, so the row is placed
    /// under a locally generated one. It is replaced by the real uid at the next load — until
    /// then the row renders and can be reordered, but removing it needs the reload, which is why
    /// `PlaylistService` refreshes after an add.
    func addTrackToPlaylist(_ trackId: String, playlistId: String) {
        playlists[playlistId]?.items.append(
            PlaylistItem(uid: "local:\(UUID().uuidString)", trackId: trackId),
        )
        // Recalculate duration if we have the track
        if let track = tracks[trackId] {
            let currentDuration = playlists[playlistId]?.totalDurationMs ?? 0
            playlists[playlistId]?.totalDurationMs = currentDuration + track.durationMs
        }
    }

    /// Remove **one occurrence** from a playlist, named by its uid.
    ///
    /// By uid rather than by track id: a playlist may hold the same song more than once, and
    /// removing "the track" would take every copy — which is what the Web API path did.
    func removePlaylistItem(uid: String, playlistId: String) {
        guard let index = playlists[playlistId]?.items.firstIndex(where: { $0.uid == uid }) else {
            return
        }

        let trackId = playlists[playlistId]?.items[index].trackId
        if let trackId, let track = tracks[trackId], let currentDuration = playlists[playlistId]?.totalDurationMs {
            playlists[playlistId]?.totalDurationMs = max(0, currentDuration - track.durationMs)
        }
        playlists[playlistId]?.items.remove(at: index)
    }

    /// Move an item within a playlist (reorder)
    func movePlaylistTrack(playlistId: String, fromIndex: Int, toIndex: Int) {
        guard var items = playlists[playlistId]?.items,
              fromIndex >= 0, fromIndex < items.count,
              toIndex >= 0, toIndex < items.count,
              fromIndex != toIndex
        else { return }

        items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        playlists[playlistId]?.items = items
    }

    /// Update playlist details
    func updatePlaylistDetails(id: String, name: String? = nil, description: String? = nil, isPublic: Bool? = nil) {
        if let name {
            playlists[id]?.name = name
        }
        if let description {
            playlists[id]?.description = description
        }
        if let isPublic {
            playlists[id]?.isPublic = isPublic
        }
    }

    /// Add a new playlist to user's library
    func addPlaylistToUserLibrary(_ playlist: Playlist) {
        upsertPlaylist(playlist)
        userPlaylistIds.insert(playlist.id, at: 0)
    }

    /// Remove playlist from user's library
    func removePlaylistFromUserLibrary(_ playlistId: String) {
        userPlaylistIds.removeAll { $0 == playlistId }
        playlists.removeValue(forKey: playlistId)
        deletedEntitySelections.insert(.playlist(id: playlistId))
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
        deletedEntitySelections.remove(.album(id: albumId))
        userAlbumIds.insert(albumId, at: 0)
    }

    /// Add artist to user's followed artists
    func addArtistToUserLibrary(_ artistId: String) {
        guard !userArtistIds.contains(artistId) else { return }
        deletedEntitySelections.remove(.artist(id: artistId))
        userArtistIds.insert(artistId, at: 0)
    }

    /// Add playlist to user's library (for followed playlists)
    func addPlaylistToUserLibraryById(_ playlistId: String) {
        guard !userPlaylistIds.contains(playlistId) else { return }
        deletedEntitySelections.remove(.playlist(id: playlistId))
        userPlaylistIds.insert(playlistId, at: 0)
    }

    // MARK: - Search Actions

    func searchResults(for query: String) -> SearchResults? {
        searchResultsByQuery[query]
    }

    func setSearchResults(_ results: SearchResults, for query: String) {
        searchResultsByQuery[query] = results
        searchResultQueries.removeAll { $0 == query }
        searchResultQueries.append(query)

        // One query enters per call, so at most one leaves. The revision is what tells
        // navigation to invalidate the history entries the evicted query can no longer serve.
        guard searchResultQueries.count > Self.searchResultsLimit else { return }
        let evicted = searchResultQueries.removeFirst()
        searchResultsByQuery.removeValue(forKey: evicted)
        if lastDisplayedSearchQuery == evicted {
            lastDisplayedSearchQuery = nil
        }
        searchCacheEvictionRevision &+= 1
    }

    func markSearchQueryDisplayed(_ query: String) {
        guard searchResultsByQuery[query] != nil else { return }
        lastDisplayedSearchQuery = query
    }

    func clearSearchError() {
        searchErrorMessage = nil
    }

    // MARK: - Start Page Actions

    /// Replaces the whole page. Shelves are not merged across loads: Spotify rebuilds this list
    /// on every request — 31 sections in the same account differed in order and membership
    /// between two requests three minutes apart — so keeping an old shelf that no longer came
    /// back would show something Spotify has stopped recommending.
    func setHomePage(sections: [HomeSection], greeting: String?) {
        homeSections = sections
        homeGreeting = greeting
    }

    // MARK: - Live State Freshness

    /// Monotonic counter bumped whenever live playback or queue state from Rust is accepted.
    ///
    /// The Web API bootstrap captures this before issuing its requests and re-checks it
    /// before applying the response, so a Rust callback that lands while those requests are
    /// in flight wins over the older network snapshot. Without it, reconnecting or
    /// transferring could show the correct live state and then replace it with a stale
    /// Web API one.
    ///
    /// Deliberately one counter for playback and queue together rather than two. Splitting
    /// them looks more precise but is not: both halves carry the current track, so a
    /// per-half check lets a stale queue response reinstate the track a live playback
    /// callback has just moved on from. All-or-nothing keeps the two consistent.
    ///
    /// It is coarser — a queue response can be discarded because a playback callback
    /// arrived — and that costs nothing for the callers whose live callbacks are replacing
    /// the state anyway. The one caller it does cost is the refresh scheduled after a
    /// provisional `SetQueue`, which is waiting for a queue no callback is going to deliver;
    /// that one retries (see `QueueService.scheduleQueueRefresh`).
    private(set) var liveStateRevision: UInt64 = 0

    /// Records that authoritative state arrived from Rust.
    func noteLiveStateReceived() {
        liveStateRevision &+= 1
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

    /// Aligns the queue's current pointer with the authoritative logical track identity.
    /// Returns whether the split changed.
    @discardableResult
    func reconcileQueueCurrentTrack(with trackId: String) -> Bool {
        let reconciledQueue = queue.reconciled(currentTrackId: trackId)
        guard reconciledQueue != queue else { return false }
        queue = reconciledQueue
        return true
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
                let artistAlbumIds: [String: [String]]

                let userPlaylistIds: [String]
                let userAlbumIds: [String]
                let userArtistIds: [String]
                let favoriteTrackIds: [String]
                let savedTrackIds: [String]

                let playlistsPagination: PaginationState
                let albumsPagination: PaginationState
                let artistsPagination: PaginationState
                let favoritesPagination: PaginationState

                let searchResultsByQuery: [String: SearchResults]
                let searchResultQueries: [String]
                let lastDisplayedSearchQuery: String?

                let homeSections: [HomeSection]

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
                artistAlbumIds: artistAlbumIds,
                userPlaylistIds: userPlaylistIds,
                userAlbumIds: userAlbumIds,
                userArtistIds: userArtistIds,
                favoriteTrackIds: Array(favoriteTrackIds),
                savedTrackIds: savedTrackIds,
                playlistsPagination: playlistsPagination,
                albumsPagination: albumsPagination,
                artistsPagination: artistsPagination,
                favoritesPagination: favoritesPagination,
                searchResultsByQuery: searchResultsByQuery,
                searchResultQueries: searchResultQueries,
                lastDisplayedSearchQuery: lastDisplayedSearchQuery,
                homeSections: homeSections,
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
