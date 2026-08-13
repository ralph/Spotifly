//
//  PathfinderEntities.swift
//  Spotifly
//
//  Turning pathfinder results into the entities AppStore holds.
//

import Foundation

/// # Identity
///
/// Pathfinder resolves the catalogue against the account server-side and returns one entity,
/// whose `id` and `uri` are the identity. There is no `linked_from`, no second id, and nothing
/// to unwind — so these conversions take the id as given.
///
/// That measurement is what set the app's rule rather than the other way round: pathfinder
/// returns the market recording and offers no way back to the original, so the market id is the
/// identity everywhere (`AGENTS.md`, "Track identity is the market id"). The Web API path was
/// changed to match, not this one.
extension ImageSet {
    /// Pathfinder returns image sources with dimensions, in the same shape as the Web API's
    /// images once unwrapped.
    init(pathfinderSources sources: [PathfinderImage.Source]?) {
        let variants = (sources ?? []).compactMap { source -> ImageVariant? in
            guard let urlString = source.url, let url = URL(string: urlString) else { return nil }
            return ImageVariant(url: url, size: source.width ?? source.height ?? 0)
        }
        self.init(variants: variants.sorted { $0.size > $1.size })
    }
}

extension Track {
    /// Nil when the result carries no id or uri — an entity `AppStore` could not key.
    init?(pathfinder track: PathfinderTrack) {
        guard let id = track.id, let uri = track.uri else { return nil }

        self.init(
            id: id,
            name: track.name ?? "",
            uri: uri,
            durationMs: track.durationMs ?? 0,
            trackNumber: nil,
            externalUrl: nil,
            albumId: track.albumOfTrack?.id ?? track.albumOfTrack?.uri.flatMap(SpotifyURI.id(from:)),
            artistId: track.artists?.items?.first?.id,
            artistName: track.artistNames.first ?? "Unknown",
            albumName: track.albumOfTrack?.name,
            images: ImageSet(pathfinderSources: track.albumOfTrack?.coverArt?.sources),
        )
    }
}

extension Album {
    init?(pathfinder album: PathfinderAlbum) {
        guard let id = album.id, let uri = album.uri else { return nil }

        self.init(
            id: id,
            name: album.name ?? "",
            uri: uri,
            images: ImageSet(pathfinderSources: album.coverArt?.sources),
            // Search returns only the year, where the Web API returns a full date. Rendered as
            // a year either way, so this is parity rather than loss.
            releaseDate: album.date?.year.map(String.init),
            albumType: album.type?.lowercased(),
            externalUrl: nil,
            artistId: album.artists?.items?.first?.id,
            artistName: album.artistNames.first ?? "Unknown",
            trackIds: [],
            totalDurationMs: nil,
            // Search carries no track count, and claiming zero would be a lie the album view
            // would then display. The detail load fills it in.
            knownTrackCount: 0,
            detailsLoaded: false,
        )
    }
}

extension PathfinderAlbumUnion {
    /// The store entities this album resolves to: the album itself, and its tracks in order.
    ///
    /// One place rather than two, because the album and its tracks have to agree — the album's
    /// `trackIds` are the ids of exactly the tracks returned beside it, and a track id the
    /// store has no track for is a row the album view cannot render. Both the album screen and
    /// the recently-played strip go through here.
    func entities() -> (album: Album, tracks: [Track])? {
        guard let albumId = id else { return nil }

        // Built first, because the album's track ids are whichever of these survived.
        let images = ImageSet(pathfinderSources: coverArt?.sources)
        let albumTracks = tracks.compactMap {
            Track(
                pathfinderAlbumTrack: $0,
                albumId: albumId,
                albumName: name,
                images: images,
            )
        }

        guard let album = Album(
            pathfinderUnion: self,
            trackIds: albumTracks.map(\.id),
            totalDurationMs: albumTracks.reduce(0) { $0 + $1.durationMs },
        ) else {
            return nil
        }

        return (album, albumTracks)
    }
}

extension Album {
    /// An album from `getAlbum`, with its track list already resolved.
    ///
    /// Takes `trackIds` rather than deriving them, because the caller stores the tracks and has
    /// to agree with this about which ones made it in — an id here that `AppStore` has no track
    /// for is a row the album view cannot render.
    init?(pathfinderUnion album: PathfinderAlbumUnion, trackIds: [String], totalDurationMs: Int?) {
        guard let id = album.id, let uri = album.uri else { return nil }

        let artist = album.firstArtist

        self.init(
            id: id,
            name: album.name ?? "",
            uri: uri,
            images: ImageSet(pathfinderSources: album.coverArt?.sources),
            releaseDate: album.date?.day,
            // `ALBUM`, `SINGLE`, `COMPILATION` — the Web API's lowercase spelling is what the
            // views compare against.
            albumType: album.type?.lowercased(),
            externalUrl: nil,
            artistId: artist?.id ?? artist?.uri.flatMap(SpotifyURI.id(from:)),
            artistName: artist?.profile?.name ?? "Unknown",
            trackIds: trackIds,
            totalDurationMs: totalDurationMs,
            // Nil rather than the reported total: the tracks are here, so the views count them
            // instead of trusting a number that could disagree with the rows on screen.
            knownTrackCount: nil,
            detailsLoaded: true,
            tracksLoaded: true,
        )
    }
}

extension Track {
    /// One track of an album.
    ///
    /// The album context is passed in because the track carries none — `getAlbum` returns the
    /// album once and its tracks beneath it, so repeating the cover art on every track would be
    /// the response saying the same thing twenty times.
    init?(
        pathfinderAlbumTrack track: PathfinderAlbumTrack,
        albumId: String,
        albumName: String?,
        images: ImageSet,
    ) {
        guard let id = track.id, let uri = track.uri else { return nil }

        self.init(
            id: id,
            name: track.name ?? "",
            uri: uri,
            durationMs: track.duration?.totalMilliseconds ?? 0,
            trackNumber: track.trackNumber,
            externalUrl: nil,
            albumId: albumId,
            artistId: track.firstArtistId,
            artistName: track.artistNames.first ?? "Unknown",
            albumName: albumName,
            images: images,
        )
    }
}

extension Artist {
    init?(pathfinder artist: PathfinderArtist) {
        guard let id = artist.id, let uri = artist.uri else { return nil }

        self.init(
            id: id,
            name: artist.name ?? "",
            uri: uri,
            images: ImageSet(pathfinderSources: artist.visuals?.avatarImage?.sources),
            externalUrl: nil,
        )
    }

    /// From `queryArtistOverview`, which is where the artist page gets its identity.
    init?(pathfinderOverview artist: PathfinderArtistUnion) {
        guard let id = artist.artistId else { return nil }

        self.init(
            id: id,
            name: artist.profile?.name ?? "",
            uri: artist.uri ?? "spotify:artist:\(id)",
            images: ImageSet(pathfinderSources: artist.visuals?.avatarImage?.sources),
            externalUrl: nil,
        )
    }
}

extension Album {
    /// One release from an artist's discography.
    ///
    /// Thinner than `init?(pathfinderUnion:…)`: a discography entry has no track list, so the
    /// album lands with `detailsLoaded` false and opening it fetches the rest. `knownTrackCount`
    /// comes from the release's own count, so the list can show "12 tracks" without that fetch.
    init?(pathfinderRelease release: PathfinderRelease, artistId: String?, artistName: String) {
        guard let id = release.releaseId else { return nil }

        self.init(
            id: id,
            name: release.name ?? "",
            uri: release.uri ?? "spotify:album:\(id)",
            images: ImageSet(pathfinderSources: release.coverArt?.sources),
            releaseDate: release.date?.formatted,
            albumType: release.type?.lowercased(),
            externalUrl: nil,
            artistId: artistId,
            artistName: artistName,
            trackIds: [],
            totalDurationMs: nil,
            knownTrackCount: release.tracks?.totalCount ?? 0,
            detailsLoaded: false,
        )
    }
}

extension Playlist {
    init?(pathfinder playlist: PathfinderPlaylist) {
        guard let id = playlist.id, let uri = playlist.uri else { return nil }

        let owner = playlist.ownerV2?.data

        self.init(
            id: id,
            name: playlist.name ?? "",
            description: playlist.description,
            images: ImageSet(pathfinderSources: (playlist.images?.items ?? []).first?.sources),
            uri: uri,
            isPublic: true,
            // Pathfinder identifies the owner by name, not by id. Used for display only here;
            // the playlist detail load supplies the id when it is needed.
            ownerId: owner?.username ?? "",
            ownerName: owner?.name ?? owner?.username ?? "",
            externalUrl: nil,
            trackIds: [],
            totalDurationMs: nil,
            knownTrackCount: 0,
        )
    }
}
