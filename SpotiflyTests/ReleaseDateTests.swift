//
//  ReleaseDateTests.swift
//  SpotiflyTests
//
//  An album's release date is kept as precise as Spotify knows it, and shown in the app's
//  language. Until 2026-10-02 the header showed the ISO day, "1969-09-26", in every language,
//  and "1971-01-01" for an album Spotify dates only to 1971.
//

import Foundation
@testable import Spotifly
import Testing

struct ReleaseDateTests {
    private func formatted(_ json: String) throws -> String? {
        try JSONDecoder().decode(PathfinderReleaseDate.self, from: Data(json.utf8)).formatted
    }

    /// Spotify writes a date it only knows the year of as that year's first of January. This is
    /// `getAlbum`'s and `libraryV3`'s shape for Rodriguez, "Coming From Reality", measured
    /// 2026-10-02, with each precision.
    @Test(arguments: [
        ("YEAR", "1971"),
        ("MONTH", "1971-01"),
        ("DAY", "1971-01-01"),
    ])
    func `a timestamp is cut to its precision`(precision: String, expected: String) throws {
        #expect(try formatted(#"{"isoString":"1971-01-01T00:00:00Z","precision":"\#(precision)"}"#) == expected)
    }

    @Test func `an unknown precision keeps the day`() throws {
        #expect(try formatted(#"{"isoString":"2001-03-12T00:00:00Z"}"#) == "2001-03-12")
    }

    /// An artist page's overview spells the date in parts.
    @Test func `a date in parts is cut to its precision too`() throws {
        #expect(try formatted(#"{"day":1,"month":5,"year":1971,"precision":"MONTH"}"#) == "1971-05")
    }

    /// Search sends the year alone.
    @Test func `a year alone is the year`() throws {
        #expect(try formatted(#"{"year":1994}"#) == "1994")
    }

    @Test(arguments: [
        ("en_US", "Sep 26, 1969"),
        ("de_DE", "26. Sept. 1969"),
        ("fr_FR", "26 sept. 1969"),
    ])
    func `a day is written in the locale's words`(locale: String, expected: String) {
        let formatted = formatReleaseDate("1969-09-26", locale: Locale(identifier: locale))

        #expect(formatted.replacing(/\s/, with: " ") == expected)
    }

    @Test func `a month and a year are written as precisely as they are known`() {
        let german = Locale(identifier: "de_DE")

        #expect(formatReleaseDate("1971-05", locale: german) == "Mai 1971")
        #expect(formatReleaseDate("1971", locale: german) == "1971")
    }

    @Test func `anything else is shown as it came`() {
        #expect(formatReleaseDate("soon", locale: Locale(identifier: "en_US")) == "soon")
    }
}
