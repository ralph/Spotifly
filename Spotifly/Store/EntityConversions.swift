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
        images = track.images
    }

    /// Convert from APITrack with album context override
    /// Used when album info isn't included in the API response (e.g., album tracks endpoint)
    init(from track: APITrack, albumId: String, albumName: String, images: ImageSet) {
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
        self.images = images
    }
}

// MARK: - Album Conversions

extension Album {
    /// Convert from APIAlbum.
    ///
    /// Every endpoint that produces an `APIAlbum` — `/albums/{id}`, `/me/albums`,
    /// `/artists/{id}/albums`, search — returns the full set of fields this entity
    /// has, so the result counts as details-loaded.
    init(from album: APIAlbum) {
        self.init(
            id: album.id,
            name: album.name,
            uri: album.uri,
            images: album.images,
            releaseDate: album.releaseDate,
            albumType: album.albumType,
            externalUrl: album.externalUrl,
            artistId: album.artistId,
            artistName: album.artistName,
            trackIds: [],
            totalDurationMs: album.totalDurationMs,
            knownTrackCount: album.trackCount,
            detailsLoaded: true,
        )
    }

    /// Create with explicit track IDs (when loading album details with tracks)
    init(from album: APIAlbum, trackIds: [String], totalDurationMs: Int?) {
        self.init(
            id: album.id,
            name: album.name,
            uri: album.uri,
            images: album.images,
            releaseDate: album.releaseDate,
            albumType: album.albumType,
            externalUrl: album.externalUrl,
            artistId: album.artistId,
            artistName: album.artistName,
            trackIds: trackIds,
            totalDurationMs: totalDurationMs,
            knownTrackCount: nil, // We have actual tracks
            detailsLoaded: true,
            tracksLoaded: true,
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
        images = artist.images
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
            description: playlist.description.normalizedPlaylistDescription,
            images: playlist.images,
            uri: playlist.uri,
            isPublic: playlist.isPublic ?? true,
            ownerId: playlist.ownerId,
            ownerName: playlist.ownerName,
            externalUrl: playlist.externalUrl,
            items: [],
            totalDurationMs: playlist.totalDurationMs,
            knownTrackCount: playlist.trackCount,
        )
    }

    /// Create with explicit items (when loading playlist details with tracks)
    init(from playlist: APIPlaylist, items: [PlaylistItem], totalDurationMs: Int?) {
        self.init(
            id: playlist.id,
            name: playlist.name,
            description: playlist.description.normalizedPlaylistDescription,
            images: playlist.images,
            uri: playlist.uri,
            isPublic: playlist.isPublic ?? true,
            ownerId: playlist.ownerId,
            ownerName: playlist.ownerName,
            externalUrl: playlist.externalUrl,
            items: items,
            totalDurationMs: totalDurationMs,
            knownTrackCount: nil, // We have actual tracks
            tracksLoaded: true,
        )
    }
}

extension String? {
    /// Spotify's playlist list answers with the literal string `"null"` when a playlist has no
    /// description, and the detail header rendered it verbatim — the view's `?? ""` never saw a
    /// nil to fall back from. Normalised at the entity boundary rather than in the view, so
    /// every reader gets the same answer.
    var normalizedPlaylistDescription: String? {
        guard let self, self != "null", !self.isEmpty else { return nil }
        return self
    }
}
