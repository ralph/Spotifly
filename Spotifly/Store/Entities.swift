//
//  Entities.swift
//  Spotifly
//
//  Unified entity models for normalized state management.
//  These are the canonical representations stored in AppStore.
//

import Foundation

// MARK: - Track

/// Unified track entity - single source of truth for all track data.
/// Constructed from APITrack via EntityConversions.
struct Track: Identifiable, Sendable, Hashable, Encodable {
    let id: String
    let name: String
    let uri: String
    let durationMs: Int
    let trackNumber: Int?
    let externalUrl: String?

    // Relationships (stored as IDs, not nested objects)
    let albumId: String?
    let artistId: String?

    // Denormalized for display (avoids extra lookups for common display patterns)
    let artistName: String
    let albumName: String?
    let imageURL: URL?

    var durationFormatted: String {
        formatTrackTime(milliseconds: durationMs)
    }

    /// Returns externalUrl if available, otherwise generates from ID
    var externalUrlOrGenerated: String {
        externalUrl ?? spotifyExternalUrl(type: .track, id: id)
    }
}

// MARK: - Album

/// Unified album entity.
struct Album: Identifiable, Sendable, Hashable, Encodable {
    let id: String
    let name: String
    let uri: String
    let imageURL: URL?
    let releaseDate: String?
    let albumType: String?
    let externalUrl: String?

    // Relationships
    let artistId: String?
    let artistName: String // Denormalized for display

    // Mutable state (populated when tracks are loaded)
    var trackIds: [String]
    var totalDurationMs: Int?

    /// Known count from API (before tracks are loaded)
    private var _knownTrackCount: Int?

    /// Track count - uses loaded trackIds if available, otherwise falls back to API count
    var trackCount: Int {
        trackIds.isEmpty ? (_knownTrackCount ?? 0) : trackIds.count
    }

    /// Whether tracks have been loaded
    var tracksLoaded: Bool {
        !trackIds.isEmpty
    }

    var formattedDuration: String? {
        guard let totalDurationMs else { return nil }
        return formatDuration(milliseconds: totalDurationMs)
    }

    /// Memberwise initializer with all fields
    init(
        id: String,
        name: String,
        uri: String,
        imageURL: URL?,
        releaseDate: String?,
        albumType: String?,
        externalUrl: String?,
        artistId: String?,
        artistName: String,
        trackIds: [String] = [],
        totalDurationMs: Int? = nil,
        knownTrackCount: Int? = nil,
    ) {
        self.id = id
        self.name = name
        self.uri = uri
        self.imageURL = imageURL
        self.releaseDate = releaseDate
        self.albumType = albumType
        self.externalUrl = externalUrl
        self.artistId = artistId
        self.artistName = artistName
        self.trackIds = trackIds
        self.totalDurationMs = totalDurationMs
        _knownTrackCount = knownTrackCount
    }
}

// MARK: - Artist

/// Unified artist entity.
struct Artist: Identifiable, Sendable, Hashable, Encodable {
    let id: String
    let name: String
    let uri: String
    let imageURL: URL?
    let genres: [String]
    let externalUrl: String?
}

// MARK: - Playlist

/// Unified playlist entity.
struct Playlist: Identifiable, Sendable, Hashable, Encodable {
    let id: String
    var name: String // Mutable - can be edited
    var description: String?
    var imageURL: URL?
    let uri: String
    var isPublic: Bool
    let ownerId: String
    let ownerName: String
    let externalUrl: String?

    // Mutable state (populated when tracks are loaded)
    var trackIds: [String]
    var totalDurationMs: Int?

    /// Known count from API (before tracks are loaded)
    private var _knownTrackCount: Int?

    /// Track count - uses loaded trackIds if available, otherwise falls back to API count
    var trackCount: Int {
        trackIds.isEmpty ? (_knownTrackCount ?? 0) : trackIds.count
    }

    /// Whether tracks have been loaded
    var tracksLoaded: Bool {
        !trackIds.isEmpty
    }

    var formattedDuration: String? {
        guard let totalDurationMs else { return nil }
        return formatDuration(milliseconds: totalDurationMs)
    }

    /// Memberwise initializer with all fields
    init(
        id: String,
        name: String,
        description: String?,
        imageURL: URL?,
        uri: String,
        isPublic: Bool,
        ownerId: String,
        ownerName: String,
        externalUrl: String? = nil,
        trackIds: [String] = [],
        totalDurationMs: Int? = nil,
        knownTrackCount: Int? = nil,
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.uri = uri
        self.isPublic = isPublic
        self.ownerId = ownerId
        self.ownerName = ownerName
        self.externalUrl = externalUrl
        self.trackIds = trackIds
        self.totalDurationMs = totalDurationMs
        _knownTrackCount = knownTrackCount
    }
}

// MARK: - User Profile

/// User profile (singleton, not stored in entity table).
struct UserProfile: Sendable {
    let id: String
    let displayName: String
    let imageURL: URL?
    let externalUrl: String?
    let uri: String?
}

// MARK: - Device

/// Spotify Connect device.
struct Device: Identifiable, Sendable, Hashable, Encodable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let volumePercent: Int?
}

// MARK: - Spotify Connection

/// Our app's connection state to Spotify (single source of truth for connection info).
/// Converted from LibrespotConnectionState at the FFI boundary.
struct SpotifyConnection: Sendable, Equatable, Encodable {
    let deviceId: String?
    let deviceName: String
    let isConnected: Bool
    let connectionId: String?
    let connectedSince: Date?
    let spircReady: Bool
    let reconnectAttempts: UInt32
    let lastError: String?
}

// MARK: - Queue Models

/// Indicates the source of a track in the queue (matches librespot provider values)
enum TrackProvider: String, Codable, Sendable {
    case queue // Manually added to queue
    case context // From current album/playlist/artist
    case autoplay // Autoplay suggestion
    case unavailable // Track is unavailable

    /// Parse from librespot provider string
    init(from providerString: String) {
        switch providerString {
        case "queue": self = .queue
        case "context": self = .context
        case "autoplay": self = .autoplay
        case "unavailable": self = .unavailable
        default: self = .unavailable // Unknown provider values treated as unavailable
        }
    }
}

/// A track in the queue with provider information
struct QueueTrack: Identifiable, Sendable {
    let id: String // Unique ID for list diffing (track.id + index or UUID)
    let track: Track
    let provider: TrackProvider

    /// Create from a Track with provider info
    init(id: String = UUID().uuidString, track: Track, provider: TrackProvider) {
        self.id = id
        self.track = track
        self.provider = provider
    }
}

/// Represents the current playback queue state
struct PlaybackQueue: Sendable {
    var currentTrack: QueueTrack?
    var manualQueue: [QueueTrack] // Manually queued tracks (provider: .queue)
    var contextTracks: [QueueTrack] // Tracks from current context (provider: .context)

    /// All upcoming tracks - manual queue plays first, then context
    var allUpcoming: [QueueTrack] {
        manualQueue + contextTracks
    }

    /// Total count of upcoming tracks
    var upcomingCount: Int {
        manualQueue.count + contextTracks.count
    }

    init(currentTrack: QueueTrack? = nil, manualQueue: [QueueTrack] = [], contextTracks: [QueueTrack] = []) {
        self.currentTrack = currentTrack
        self.manualQueue = manualQueue
        self.contextTracks = contextTracks
    }
}

// MARK: - Duration Formatting

/// Format milliseconds as track time (e.g., "3:45")
nonisolated func formatTrackTime(milliseconds: Int) -> String {
    let totalSeconds = milliseconds / 1000
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}

/// Format milliseconds as human-readable duration (e.g., "3 hr 15 min" or "45 min")
func formatDuration(milliseconds: Int) -> String {
    let totalSeconds = milliseconds / 1000
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60

    if hours > 0 {
        return String(format: "%d hr %d min", hours, minutes)
    } else {
        return String(format: "%d min", minutes)
    }
}

/// Calculate total duration from a sequence of tracks
func totalDuration(of tracks: some Sequence<Track>) -> String {
    let totalMs = tracks.reduce(0) { $0 + $1.durationMs }
    return formatDuration(milliseconds: totalMs)
}

// MARK: - Pagination State

/// Tracks pagination state for a collection.
struct PaginationState: Sendable, Encodable {
    var isLoaded = false
    var isLoading = false
    var hasMore = true
    var nextOffset: Int? = 0
    var nextCursor: String? // For cursor-based pagination (artists)
    var total: Int = 0

    mutating func reset() {
        isLoaded = false
        isLoading = false
        hasMore = true
        nextOffset = 0
        nextCursor = nil
        total = 0
    }
}
