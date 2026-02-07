//
//  EntityConversions.swift
//  Spotifly
//
//  Conversion initializers from API response types to unified entities.
//

import Foundation

// MARK: - Track Conversions

extension Track {
    /// Convert from APITrack (unified track type from all API sources)
    init(from track: APITrack) {
        id = track.id
        name = track.name
        uri = track.uri
        durationMs = track.durationMs
        trackNumber = track.trackNumber
        externalUrl = track.externalUrl
        albumId = track.albumId
        artistId = track.artistId
        artistName = track.artistName
        albumName = track.albumName
        imageURL = track.imageURL
    }

    /// Convert from APITrack with album context override
    /// Used when album info isn't included in the API response (e.g., album tracks endpoint)
    init(from track: APITrack, albumId: String, albumName: String, imageURL: URL?) {
        id = track.id
        name = track.name
        uri = track.uri
        durationMs = track.durationMs
        trackNumber = track.trackNumber
        externalUrl = track.externalUrl
        self.albumId = albumId
        artistId = track.artistId
        artistName = track.artistName
        self.albumName = albumName
        self.imageURL = imageURL
    }
}

// MARK: - Album Conversions

extension Album {
    /// Convert from APIAlbum
    init(from album: APIAlbum) {
        self.init(
            id: album.id,
            name: album.name,
            uri: album.uri,
            imageURL: album.imageURL,
            releaseDate: album.releaseDate,
            albumType: album.albumType,
            externalUrl: album.externalUrl,
            artistId: album.artistId,
            artistName: album.artistName,
            trackIds: [],
            totalDurationMs: album.totalDurationMs,
            knownTrackCount: album.trackCount,
        )
    }

    /// Create with explicit track IDs (when loading album details with tracks)
    init(from album: APIAlbum, trackIds: [String], totalDurationMs: Int?) {
        self.init(
            id: album.id,
            name: album.name,
            uri: album.uri,
            imageURL: album.imageURL,
            releaseDate: album.releaseDate,
            albumType: album.albumType,
            externalUrl: album.externalUrl,
            artistId: album.artistId,
            artistName: album.artistName,
            trackIds: trackIds,
            totalDurationMs: totalDurationMs,
            knownTrackCount: nil, // We have actual tracks
        )
    }
}

// MARK: - Artist Conversions

extension Artist {
    /// Convert from APIArtist
    init(from artist: APIArtist) {
        id = artist.id
        name = artist.name
        uri = artist.uri
        imageURL = artist.imageURL
        genres = artist.genres
        externalUrl = artist.externalUrl
    }
}

// MARK: - User Profile Conversions

extension UserProfile {
    /// Convert from UserProfileCodable
    init(from profile: UserProfileCodable) {
        id = profile.id
        displayName = profile.displayName ?? profile.id
        imageURL = profile.images?.first.flatMap { URL(string: $0.url) }
        externalUrl = profile.externalUrls?.spotify
        uri = profile.uri
    }
}

// MARK: - Playlist Conversions

extension Playlist {
    /// Convert from APIPlaylist
    init(from playlist: APIPlaylist) {
        self.init(
            id: playlist.id,
            name: playlist.name,
            description: playlist.description,
            imageURL: playlist.imageURL,
            uri: playlist.uri,
            isPublic: playlist.isPublic ?? true,
            ownerId: playlist.ownerId,
            ownerName: playlist.ownerName,
            externalUrl: playlist.externalUrl,
            trackIds: [],
            totalDurationMs: playlist.totalDurationMs,
            knownTrackCount: playlist.trackCount,
        )
    }

    /// Create with explicit track IDs (when loading playlist details with tracks)
    init(from playlist: APIPlaylist, trackIds: [String], totalDurationMs: Int?) {
        self.init(
            id: playlist.id,
            name: playlist.name,
            description: playlist.description,
            imageURL: playlist.imageURL,
            uri: playlist.uri,
            isPublic: playlist.isPublic ?? true,
            ownerId: playlist.ownerId,
            ownerName: playlist.ownerName,
            externalUrl: playlist.externalUrl,
            trackIds: trackIds,
            totalDurationMs: totalDurationMs,
            knownTrackCount: nil, // We have actual tracks
        )
    }
}
