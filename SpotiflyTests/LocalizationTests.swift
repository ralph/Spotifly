//
//  LocalizationTests.swift
//  SpotiflyTests
//
//  Every string the code names is translated, in every language. A key without an entry shows
//  as the raw key: `playlist.loading` in every language, and `speakers.airplay_disabled_hint` in
//  German, until 2026-10-02.
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

    @Test(arguments: Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" })
    func `a language names the same strings as English`(language: String) throws {
        let english = try keys("en")
        let other = try keys(language)

        #expect(english.subtracting(other).sorted() == [], "missing in \(language)")
        #expect(other.subtracting(english).sorted() == [], "only in \(language)")
    }
}
