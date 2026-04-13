//
//  Entities.swift
//  Spotifly
//
//  Unified entity models for normalized state management.
//  These are the canonical representations stored in AppStore.
//

import Foundation

// MARK: - Image Types

/// A single image variant with its URL and pixel dimensions.
struct ImageVariant: Hashable, Encodable {
    let url: URL
    let size: Int // width in pixels (images are square)
}

/// A collection of image variants at different resolutions.
/// Stores all sizes returned by the Spotify API and provides
/// resolution-aware selection based on display size and scale.
struct ImageSet: Hashable, Encodable {
    /// Sorted descending by size (largest first), matching Spotify's default order.
    let variants: [ImageVariant]

    /// Returns the best image URL for a given display size in points.
    ///
    /// Uses 20% tolerance — accepts a variant that covers at least 80% of the
    /// target pixel size. This lets small views (34–40pt) use the 64px variant
    /// instead of downloading the 300px image.
    ///
    /// - Parameters:
    ///   - points: The display size in SwiftUI points (e.g. 120 for a 120×120pt view).
    ///   - scale: The display scale factor (1.0 for non-retina, 2.0 for retina).
    ///            Defaults to 2.0 since all modern Macs are retina.
    /// - Returns: The URL of the best-fit image, or nil if no variants exist.
    func url(for points: CGFloat, scale: CGFloat = 2.0) -> URL? {
        guard !variants.isEmpty else { return nil }
        let target = Int(points * scale)
        let threshold = target * 4 / 5
        // Smallest variant >= threshold, fallback to largest
        let best = variants.reversed().first(where: { $0.size >= threshold })
        return (best ?? variants.first)?.url
    }

    /// The medium image URL (~300px), suitable for Now Playing metadata
    /// and general-purpose use where display size is unknown.
    var mediumURL: URL? {
        let medium = variants.first(where: { $0.size <= 400 && $0.size >= 100 })
        return (medium ?? variants.first)?.url
    }

    var isEmpty: Bool {
        variants.isEmpty
    }

    /// An empty image set with no variants.
    static let empty = ImageSet(variants: [])
}

// MARK: - Track

/// Unified track entity - single source of truth for all track data.
/// Constructed from APITrack via EntityConversions.
struct Track: Identifiable, Hashable, Encodable {
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
    let images: ImageSet

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
struct Album: Identifiable, Hashable, Encodable {
    let id: String
    let name: String
    let uri: String
    let images: ImageSet
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
        images: ImageSet,
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
        self.images = images
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
struct Artist: Identifiable, Hashable, Encodable {
    let id: String
    let name: String
    let uri: String
    let images: ImageSet
    let genres: [String]
    let externalUrl: String?
}

// MARK: - Playlist

/// Unified playlist entity.
struct Playlist: Identifiable, Hashable, Encodable {
    let id: String
    var name: String // Mutable - can be edited
    var description: String?
    var images: ImageSet
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
        images: ImageSet,
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
        self.images = images
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
struct UserProfile {
    let id: String
    let displayName: String
    let imageURL: URL?
    let externalUrl: String?
    let uri: String?
}

// MARK: - Device

/// Spotify Connect device.
struct Device: Identifiable, Hashable, Encodable {
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
struct SpotifyConnection: Equatable, Encodable {
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
enum TrackProvider: String, Codable {
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
struct QueueTrack: Identifiable {
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
struct PlaybackQueue {
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
    // Using String(format:) intentionally: .formatted() is locale-sensitive and
    // can produce non-ASCII digits (e.g. Arabic-Indic) in some locales. Track
    // time is a technical display value that must always render as ASCII "3:05".
    return String(format: "%d:%02d", minutes, seconds)
}

/// Format milliseconds as human-readable duration (e.g., "3 hr 15 min" or "45 min")
func formatDuration(milliseconds: Int) -> String {
    let totalSeconds = milliseconds / 1000
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60

    if hours > 0 {
        return "\(hours.formatted()) hr \(minutes.formatted()) min"
    } else {
        return "\(minutes.formatted()) min"
    }
}

/// Calculate total duration from a sequence of tracks
func totalDuration(of tracks: some Sequence<Track>) -> String {
    let totalMs = tracks.reduce(0) { $0 + $1.durationMs }
    return formatDuration(milliseconds: totalMs)
}

// MARK: - Pagination State

/// Tracks pagination state for a collection.
struct PaginationState: Encodable {
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
