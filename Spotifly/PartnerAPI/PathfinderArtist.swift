//
//  PathfinderArtist.swift
//  Spotifly
//
//  What the artist operations send back.
//

import Foundation

/// `{ "data": { "artistUnion": { … } } }`
///
/// Shared by `queryArtistOverview` and `queryArtistDiscographyAll`, which return the same
/// envelope with different parts filled in — the overview brings a profile and a sampled
/// discography, the discography query brings `discography.all` and nothing else.
nonisolated struct PathfinderArtistResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let artistUnion: PathfinderArtistUnion?
    }

    let data: Payload?
}

/// # Genres
///
/// **There are none, anywhere.** Measured on 2026-08-13 against `queryArtistOverview`,
/// `queryArtistDiscographyAll`, `queryArtistMinimal` and spclient's `metadata/4/artist` — the
/// Web API's `/artists/{id}` returns `genres` and none of the client's own APIs do. Spotify's
/// own artist pages do not show them either. So `Artist` no longer carries a genre list; the
/// row that displayed one is gone rather than permanently empty.
nonisolated struct PathfinderArtistUnion: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        let name: String?
    }

    struct Visuals: Decodable, Sendable {
        let avatarImage: PathfinderImage?
    }

    /// The discography, whichever operation filled it in.
    ///
    /// The overview splits releases into `albums`, `singles` and `compilations`, each holding
    /// a sample; `queryArtistDiscographyAll` puts every release in `all`. The app shows one
    /// list, so it reads `all` and falls back to the sampled sections.
    struct Discography: Decodable, Sendable {
        let all: PathfinderReleaseGroup?
        let albums: PathfinderReleaseGroup?
        let singles: PathfinderReleaseGroup?
        let compilations: PathfinderReleaseGroup?
    }

    let uri: String?
    let id: String?
    let profile: Profile?
    let visuals: Visuals?
    let discography: Discography?

    var artistId: String? {
        id ?? uri.flatMap(SpotifyURI.id(from:))
    }

    /// Every release this response carries, in order, deduplicated by id.
    ///
    /// Sections overlap — `popularReleasesAlbums` repeats entries from `albums` — so a page
    /// built from more than one of them would otherwise list the same album twice, which for a
    /// SwiftUI `ForEach` keyed by album id is undefined behaviour rather than a repeated row.
    var releases: [PathfinderRelease] {
        let groups = [
            discography?.all,
            discography?.albums,
            discography?.singles,
            discography?.compilations,
        ]

        var seen = Set<String>()
        return groups.compactMap(\.self).flatMap(\.releases).filter { release in
            guard let id = release.releaseId else { return false }
            return seen.insert(id).inserted
        }
    }
}

/// One section of a discography.
///
/// **Two item shapes, again.** Most sections wrap each entry as `items[].releases.items[]` —
/// a release *group*, which can hold several editions of one record. But
/// `popularReleasesAlbums` puts the release fields directly on `items[]` with no wrapper. Both
/// are accepted rather than switched on per section, for the same reason `PathfinderItems`
/// accepts both search shapes: the difference belongs to Spotify's stored queries, and the next
/// section added is as likely to take either form.
nonisolated struct PathfinderReleaseGroup: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        struct Inner: Decodable, Sendable {
            let items: [PathfinderRelease]?
        }

        let releases: Inner?
        let direct: PathfinderRelease?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()

            let wrapped = try? container.decode(Wrapper.self)
            if let inner = wrapped?.releases {
                releases = inner
                direct = nil
            } else {
                releases = nil
                direct = try? container.decode(PathfinderRelease.self)
            }
        }

        private struct Wrapper: Decodable {
            let releases: Inner?
        }

        var all: [PathfinderRelease] {
            if let releases {
                return releases.items ?? []
            }
            return direct.map { [$0] } ?? []
        }
    }

    let items: [Item]?
    let totalCount: Int?

    var releases: [PathfinderRelease] {
        (items ?? []).flatMap(\.all)
    }
}

/// One release — an album, single or compilation — as a discography lists it.
nonisolated struct PathfinderRelease: Decodable, Sendable {
    /// **The date shape differs by operation**, which a single decoder has to absorb:
    /// `queryArtistOverview` sends `{day, month, year, precision}` while
    /// `queryArtistDiscographyAll` sends `{isoString, year, precision}`. Only `year` is in both,
    /// and the artist page renders a year — so the day-level fields are assembled when present
    /// and the year used otherwise.
    struct ReleaseDate: Decodable, Sendable {
        let isoString: String?
        let year: Int?
        let month: Int?
        let day: Int?

        /// A `YYYY-MM-DD` string where the parts allow, the bare year otherwise.
        var formatted: String? {
            if let isoString {
                return String(isoString.prefix(while: { $0 != "T" }))
            }
            if let year, let month, let day {
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            return year.map(String.init)
        }
    }

    struct TrackCount: Decodable, Sendable {
        let totalCount: Int?
    }

    let uri: String?
    let id: String?
    let name: String?
    let type: String?
    let date: ReleaseDate?
    let coverArt: PathfinderImage?
    let tracks: TrackCount?

    var releaseId: String? {
        id ?? uri.flatMap(SpotifyURI.id(from:))
    }
}
