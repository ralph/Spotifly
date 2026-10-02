//
//  DurationFormattingTests.swift
//  SpotiflyTests
//
//  An album's or playlist's length is written in the app's language. Until 2026-10-02 the
//  units were English literals, so the French header said "2 hr 44 min".
//

import Foundation
@testable import Spotifly
import Testing

struct DurationFormattingTests {
    private static let twoHours44 = (2 * 3600 + 44 * 60) * 1000

    @Test(arguments: [
        ("en_US", "2 hr, 44 min"),
        ("de_DE", "2 Std., 44 Min."),
        // French keeps a number with its unit with no-break spaces, narrow before "h".
        ("fr_FR", "2\u{202F}h et 44\u{00A0}min"),
    ])
    func `hours and minutes are written in the locale's words`(locale: String, expected: String) {
        #expect(formatDuration(milliseconds: Self.twoHours44, locale: Locale(identifier: locale)) == expected)
    }

    @Test func `under an hour is minutes only`() {
        #expect(formatDuration(milliseconds: 47 * 60 * 1000, locale: Locale(identifier: "en_US")) == "47 min")
    }

    /// Whole minutes played, as before: 2:44:40 is not yet 2:45.
    @Test func `minutes are rounded down`() {
        let en = Locale(identifier: "en_US")

        #expect(formatDuration(milliseconds: Self.twoHours44 + 40000, locale: en) == "2 hr, 44 min")
        #expect(formatDuration(milliseconds: 59000, locale: en) == "0 min")
    }

    @Test func `a zero unit is left out, except for nothing at all`() {
        let en = Locale(identifier: "en_US")

        #expect(formatDuration(milliseconds: 3600 * 1000, locale: en) == "1 hr")
        #expect(formatDuration(milliseconds: 0, locale: en) == "0 min")
    }
}
