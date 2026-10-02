//
//  LocalizationTests.swift
//  SpotiflyTests
//
//  Every string the code names is translated, in every language, and every string is named by
//  the code. A key without an entry shows as the raw key: `playlist.loading` in every language,
//  and `speakers.airplay_disabled_hint` in German, until 2026-10-02.
//

import Foundation
@testable import Spotifly
import Testing

struct LocalizationTests {
    /// The keys of a language's strings, as the app bundle ships them: `Localizable.strings`, and
    /// `Localizable.stringsdict` for the strings with plural forms.
    private func keys(_ language: String) throws -> Set<String> {
        let strings = try #require(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
        )
        var keys = try Set(#require(NSDictionary(contentsOf: strings) as? [String: String]).keys)
        if let plurals = Bundle.main.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: language) {
            try keys.formUnion(#require(NSDictionary(contentsOf: plurals) as? [String: Any]).keys)
        }
        return keys
    }

    /// The keys the code names, as the compiler extracted them (`SWIFT_EMIT_LOC_STRINGS`): one
    /// `.stringsdata` file per source file, beside the object files of the build the tests run
    /// in. A literal passed as `String`, or through `Text(verbatim:)`, is not among them.
    private func keysNamedByTheCode() throws -> Set<String> {
        struct StringsData: Decodable {
            struct Entry: Decodable {
                let key: String
            }

            let source: String
            let tables: [String: [Entry]]
        }

        // …/Build/Products/<configuration>/Spotifly.app, and beside Products, the intermediates.
        let products = Bundle.main.bundleURL.deletingLastPathComponent()
        let objects = products.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Intermediates.noindex/Spotifly.build")
            .appending(path: products.lastPathComponent)
            .appending(path: "Spotifly.build/Objects-normal")
        let files = try #require(FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "stringsdata" }
        try #require(!files.isEmpty, "no .stringsdata under \(objects.path)")

        var keys = Set<String>()
        for file in files {
            let data = try JSONDecoder().decode(StringsData.self, from: Data(contentsOf: file))
            // An incremental build leaves the file of a deleted source behind.
            guard FileManager.default.fileExists(atPath: data.source) else { continue }
            keys.formUnion(data.tables["Localizable", default: []].map(\.key))
        }
        return keys
    }

    @Test func `every key the code names has an English string`() throws {
        let missing = try keysNamedByTheCode().subtracting(keys("en"))

        #expect(missing.sorted() == [])
    }

    /// The other way: a string no code names is left over from code that went. Every key has to
    /// reach the code as a literal the compiler extracts for this to hold, which is why the
    /// formatting helpers take a `LocalizedStringResource`.
    @Test func `every English string is named by the code`() throws {
        let unused = try keys("en").subtracting(keysNamedByTheCode())

        #expect(unused.sorted() == [])
    }

    /// A count of one is singular, "1 track" where it said "1 tracks". And a count is not grouped,
    /// "1007" rather than "1.007", which formatting for the key's locale would do.
    @Test(arguments: [
        ("en", 1, "1 track"), ("en", 2, "2 tracks"),
        ("de", 1, "1 Track"), ("de", 1007, "1007 Tracks"),
        ("fr", 1, "1 titre"), ("fr", 2, "2 titres"),
    ])
    @MainActor
    func `a track count takes the language's plural`(language: String, count: Int, expected: String) {
        var key = LocalizedStringResource("metadata.tracks")
        key.locale = Locale(identifier: language)

        #expect(localizedNumberString(key, count) == expected)
    }

    @Test(arguments: Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" })
    func `a language names the same strings as English`(language: String) throws {
        let english = try keys("en")
        let other = try keys(language)

        #expect(english.subtracting(other).sorted() == [], "missing in \(language)")
        #expect(other.subtracting(english).sorted() == [], "only in \(language)")
    }
}
