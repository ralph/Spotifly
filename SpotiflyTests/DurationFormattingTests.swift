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
    private static let en = Locale(identifier: "en_US")

    @Test(arguments: [
        ("en_US", "2 hr, 44 min"),
        ("de_DE", "2 Std., 44 Min."),
        ("fr_FR", "2 h et 44 min"),
    ])
    func `hours and minutes are written in the locale's words`(locale: String, expected: String) {
        let formatted = formatDuration(milliseconds: Self.twoHours44, locale: Locale(identifier: locale))

        // Which spaces are Foundation's: French has no-break ones, U+202F before "h" and U+00A0
        // before "min" (2026-10-02), and they have changed between releases before.
        #expect(formatted.replacing(/\s/, with: " ") == expected)
    }

    @Test func `under an hour is minutes only`() {
        #expect(formatDuration(milliseconds: 47 * 60 * 1000, locale: Self.en) == "47 min")
    }

    /// Whole minutes played, as before: 2:44:40 is not yet 2:45.
    @Test func `minutes are rounded down`() {
        #expect(formatDuration(milliseconds: Self.twoHours44 + 40000, locale: Self.en) == "2 hr, 44 min")
        #expect(formatDuration(milliseconds: 59000, locale: Self.en) == "0 min")
    }

    @Test func `a zero unit is left out, except for nothing at all`() {
        #expect(formatDuration(milliseconds: 3600 * 1000, locale: Self.en) == "1 hr")
        #expect(formatDuration(milliseconds: 0, locale: Self.en) == "0 min")
    }
}
