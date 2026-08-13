//
//  PathfinderEntities.swift
//  Spotifly
//
//  Turning pathfinder results into the entities AppStore holds.
//

import Foundation

/// # Identity
///
/// The Web API path resolves identity through `linked_from`: sending `market` can return a
/// playable substitute, and `toAPITrack()` maps that back to the id the caller asked for (see
/// AGENTS.md, "Track relinking and the `market` parameter").
///
/// **Pathfinder has no `linked_from`.** It resolves the catalogue against the account
/// server-side and returns one entity, whose `id` and `uri` are the identity — there is no
/// second id to reconcile, and nothing to unwind. So these conversions take the id as given,
/// which is correct for reading and for keying `AppStore`.
///
/// The open question is *writes*. Spotify's relinking documentation says a substitute id "will
/// likely return an error" when saving or removing a track, and if pathfinder is handing back
/// substitutes without saying so, an id from search would be the wrong one to save with. The
/// Web API is still what performs those writes today, and it does its own relinking, so nothing
/// here is affected yet. It has to be settled before the library and playlist writes move —
/// `plans/single-grant-partner-api.md`, task 11 onwards — and the way to settle it is to search
/// for a track known to be relinked in this market and compare the id against `/v1/tracks`.
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

extension Artist {
    init?(pathfinder artist: PathfinderArtist) {
        guard let id = artist.id, let uri = artist.uri else { return nil }

        self.init(
            id: id,
            name: artist.name ?? "",
            uri: uri,
            images: ImageSet(pathfinderSources: artist.visuals?.avatarImage?.sources),
            // Pathfinder's search projection carries no genres; the artist page loads them.
            genres: [],
            externalUrl: nil,
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
