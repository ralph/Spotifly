//
//  EntityConversions.swift
//  Spotifly
//
//  Conversion initializers from API response types to unified entities.
//

import Foundation

// MARK: - Track to TrackRowData Conversion

extension Track {
    /// Convert to TrackRowData for use with TrackRow view
    func toTrackRowData() -> TrackRowData {
        TrackRowData(
            id: id,
            uri: uri,
            name: name,
            artistName: artistName,
            albumArtURL: imageURL?.absoluteString,
            durationMs: durationMs,
            trackNumber: trackNumber,
            albumId: albumId,
            artistId: artistId,
            externalUrl: externalUrl,
        )
    }
}

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

    /// Convert from TrackMetadata (single track lookup)
    init(from metadata: TrackMetadata) {
        id = metadata.id
        name = metadata.name
        uri = "spotify:track:\(metadata.id)"
        durationMs = metadata.durationMs
        trackNumber = nil
        externalUrl = nil
        albumId = nil
        artistId = nil
        artistName = metadata.artistName
        albumName = metadata.albumName
        imageURL = metadata.albumImageURL
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
        followers = artist.followers
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
            trackIds: trackIds,
            totalDurationMs: totalDurationMs,
            knownTrackCount: nil, // We have actual tracks
        )
    }
}

// MARK: - Device Conversions

extension Device {
    /// Convert from SpotifyDevice
    init(from device: SpotifyDevice) {
        id = device.id
        name = device.name
        type = device.type
        isActive = device.isActive
        isPrivateSession = device.isPrivateSession
        isRestricted = device.isRestricted
        volumePercent = device.volumePercent
    }
}
