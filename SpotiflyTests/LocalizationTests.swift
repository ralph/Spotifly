//
//  LocalizationTests.swift
//  SpotiflyTests
//
//  The three languages name the same strings. A key one of them lacks shows as the raw key in
//  that language: Speakers read `speakers.airplay_disabled_hint` in German until 2026-10-02.
//

import Foundation
import Testing

struct LocalizationTests {
    /// The keys of a language's `Localizable.strings`, as the app bundle ships it.
    private func keys(_ language: String) throws -> Set<String> {
        let url = try #require(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
        )
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        return Set(table.keys)
    }

    @Test(arguments: ["de", "fr"])
    func `a language names the same strings as English`(language: String) throws {
        let english = try keys("en")
        let other = try keys(language)

        #expect(english.subtracting(other).sorted() == [], "missing in \(language)")
        #expect(other.subtracting(english).sorted() == [], "only in \(language)")
    }
}
