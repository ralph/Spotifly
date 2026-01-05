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
/// Constructed from SearchTrack, SavedTrack, AlbumTrack, PlaylistTrack, or TrackMetadata.
struct Track: Identifiable, Sendable, Hashable {
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
        let totalSeconds = durationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Album

/// Unified album entity.
struct Album: Identifiable, Sendable, Hashable {
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

    // Known count from API (before tracks are loaded)
    private var _knownTrackCount: Int?

    /// Track count - uses loaded trackIds if available, otherwise falls back to API count
    var trackCount: Int {
        trackIds.isEmpty ? (_knownTrackCount ?? 0) : trackIds.count
    }

    /// Whether tracks have been loaded
    var tracksLoaded: Bool { !trackIds.isEmpty }

    var formattedDuration: String? {
        guard let totalDurationMs else { return nil }
        let totalSeconds = totalDurationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
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
struct Artist: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let uri: String
    let imageURL: URL?
    let genres: [String]
    let followers: Int?
}

// MARK: - Playlist

/// Unified playlist entity.
struct Playlist: Identifiable, Sendable, Hashable {
    let id: String
    var name: String // Mutable - can be edited
    var description: String?
    var imageURL: URL?
    let uri: String
    var isPublic: Bool
    let ownerId: String
    let ownerName: String

    // Mutable state (populated when tracks are loaded)
    var trackIds: [String]
    var totalDurationMs: Int?

    // Known count from API (before tracks are loaded)
    private var _knownTrackCount: Int?

    /// Track count - uses loaded trackIds if available, otherwise falls back to API count
    var trackCount: Int {
        trackIds.isEmpty ? (_knownTrackCount ?? 0) : trackIds.count
    }

    /// Whether tracks have been loaded
    var tracksLoaded: Bool { !trackIds.isEmpty }

    var formattedDuration: String? {
        guard let totalDurationMs else { return nil }
        let totalSeconds = totalDurationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return String(format: "%d hr %d min", hours, minutes)
        } else {
            return String(format: "%d min", minutes)
        }
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
        self.trackIds = trackIds
        self.totalDurationMs = totalDurationMs
        _knownTrackCount = knownTrackCount
    }
}

// MARK: - Device

/// Spotify Connect device.
struct Device: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
    let isPrivateSession: Bool
    let isRestricted: Bool
    let volumePercent: Int?
}

// MARK: - Pagination State

/// Tracks pagination state for a collection.
struct PaginationState: Sendable {
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
