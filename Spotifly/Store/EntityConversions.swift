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
    /// Convert from SearchTrack (search results, recently played)
    init(from searchTrack: SearchTrack) {
        id = searchTrack.id
        name = searchTrack.name
        uri = searchTrack.uri
        durationMs = searchTrack.durationMs
        trackNumber = nil
        externalUrl = searchTrack.externalUrl
        albumId = searchTrack.albumId
        artistId = searchTrack.artistId
        artistName = searchTrack.artistName
        albumName = searchTrack.albumName
        imageURL = searchTrack.imageURL
    }

    /// Convert from SavedTrack (favorites/liked tracks)
    init(from savedTrack: SavedTrack) {
        id = savedTrack.id
        name = savedTrack.name
        uri = savedTrack.uri
        durationMs = savedTrack.durationMs
        trackNumber = nil
        externalUrl = savedTrack.externalUrl
        albumId = savedTrack.albumId
        artistId = savedTrack.artistId
        artistName = savedTrack.artistName
        albumName = savedTrack.albumName
        imageURL = savedTrack.imageURL
    }

    /// Convert from AlbumTrack (album track listing)
    /// Requires album context for image and album name
    init(from albumTrack: AlbumTrack, albumId: String, albumName: String, imageURL: URL?) {
        id = albumTrack.id
        name = albumTrack.name
        uri = albumTrack.uri
        durationMs = albumTrack.durationMs
        trackNumber = albumTrack.trackNumber
        externalUrl = albumTrack.externalUrl
        self.albumId = albumId
        artistId = albumTrack.artistId
        artistName = albumTrack.artistName
        self.albumName = albumName
        self.imageURL = imageURL
    }

    /// Convert from PlaylistTrack (playlist track listing)
    init(from playlistTrack: PlaylistTrack) {
        id = playlistTrack.id
        name = playlistTrack.name
        uri = playlistTrack.uri
        durationMs = playlistTrack.durationMs
        trackNumber = nil
        externalUrl = playlistTrack.externalUrl
        albumId = playlistTrack.albumId
        artistId = playlistTrack.artistId
        artistName = playlistTrack.artistName
        albumName = playlistTrack.albumName
        imageURL = playlistTrack.imageURL
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
