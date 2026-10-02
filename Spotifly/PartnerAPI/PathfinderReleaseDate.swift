//
//  PathfinderReleaseDate.swift
//  Spotifly
//
//  A release date, in every shape pathfinder sends one.
//

import Foundation

/// A release date. **The shape differs by operation**, so one decoder takes all of them:
/// - `getAlbum` and `libraryV3`: `{isoString, precision}`;
/// - search: `{year}`;
/// - `queryArtistOverview`: `{day, month, year, precision}`;
/// - `queryArtistDiscographyAll`: `{isoString, year, precision}`.
///
/// A decoder written against one shape alone would leave the others' albums with no date.
nonisolated struct PathfinderReleaseDate: Decodable, Sendable {
    let isoString: String?
    let year: Int?
    let month: Int?
    let day: Int?
    let precision: String?

    /// As precise as Spotify knows it: `YYYY-MM-DD` for `DAY`, `YYYY-MM` for `MONTH`, `YYYY` for
    /// `YEAR`, and the bare year where that is all there is.
    ///
    /// A date Spotify only knows the year of comes as that year's first of January,
    /// `1971-01-01T00:00:00Z` with `YEAR` (Rodriguez, "Coming From Reality", measured 2026-10-02),
    /// so the day is cut to its precision rather than kept whole, which showed a day Spotify never
    /// said. An unknown or missing precision keeps the day.
    var formatted: String? {
        let fullDay = if let isoString {
            String(isoString.prefix(while: { $0 != "T" }))
        } else if let year, let month, let day {
            String(format: "%04d-%02d-%02d", year, month, day)
        } else {
            nil as String?
        }
        guard let fullDay else { return year.map(String.init) }

        return switch precision {
        case "YEAR": String(fullDay.prefix(4))
        case "MONTH": String(fullDay.prefix(7))
        default: fullDay
        }
    }
}
