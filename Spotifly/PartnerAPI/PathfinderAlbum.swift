//
//  PathfinderAlbum.swift
//  Spotifly
//
//  What `getAlbum` sends back.
//

import Foundation

/// `{ "data": { "albumUnion": { … } } }`
///
/// A different envelope from the search operations, which nest under `data.searchV2` — hence
/// its own type rather than a case in `PathfinderResponse`.
nonisolated struct PathfinderAlbumResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let albumUnion: PathfinderAlbumUnion?
    }

    let data: Payload?
}

/// An album and its tracks.
///
/// A partial view of what `getAlbum` returns, which also carries extracted cover-art colours,
/// `moreAlbumsByArtist`, `watchFeedEntrypoint`, sharing info and pre-release scheduling. Decoding
/// fields nothing renders only creates work the next time Spotify adds one.
nonisolated struct PathfinderAlbumUnion: Decodable, Sendable {
    struct ReleaseDate: Decodable, Sendable {
        let isoString: String?

        /// The Web API's `release_date` was a plain `2001-03-12`, and the views format it as a
        /// year, so the timestamp is trimmed at the `T` rather than parsed into a `Date`.
        var day: String? {
            isoString.map { String($0.prefix(while: { $0 != "T" })) }
        }
    }

    struct ArtistList: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            struct Profile: Decodable, Sendable {
                let name: String?
            }

            let id: String?
            let uri: String?
            let profile: Profile?
        }

        let items: [Item]?
    }

    /// `tracksV2`, not `tracks` — and `getAlbumNameAndTracks`, the other album operation, uses
    /// the same key for items carrying nothing but a `uri`. This is the one to ask.
    struct TrackList: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let track: PathfinderAlbumTrack?
        }

        let items: [Item]?
        let totalCount: Int?
    }

    let uri: String?
    let name: String?
    let type: String?
    let date: ReleaseDate?
    let coverArt: PathfinderImage?
    let artists: ArtistList?
    let tracksV2: TrackList?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var firstArtist: ArtistList.Item? {
        artists?.items?.first
    }

    var tracks: [PathfinderAlbumTrack] {
        (tracksV2?.items ?? []).compactMap(\.track)
    }
}

/// One track as the album view sees it.
///
/// Carries `relinkingInformation`, which search does not — so pathfinder *can* expose the
/// relink relationship on this operation. It is deliberately not decoded: the app keys tracks
/// by the market id, and the id here already is one (`AGENTS.md`, "Track identity is the market
/// id"). Reading it would only invite reintroducing the second identity that rule removed.
nonisolated struct PathfinderAlbumTrack: Decodable, Sendable {
    let uri: String?
    let name: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: PathfinderDuration?
    let artists: PathfinderArtistList?

    var id: String? {
        uri.flatMap(SpotifyURI.id(from:))
    }

    var artistNames: [String] {
        artists?.names ?? []
    }

    var firstArtistId: String? {
        artists?.firstId
    }
}
