//
//  SpotiflyTests.swift
//  SpotiflyTests
//
//  Created by Ralph von der Heyden on 30.12.25.
//

@testable import Spotifly
import Testing

@MainActor
struct SpotiflyTests {
    @Test func `favorite page refresh preserves resolved favorites outside current page`() {
        let store = AppStore()

        store.updateFavoriteStatuses([
            "outside-page": true,
            "known-false": false,
        ])
        store.setSavedTrackIds(["first-page-track"])
        store.markTracksAsFavorite(["first-page-track"])

        #expect(store.isFavorite("outside-page"))
        #expect(store.isFavorite("first-page-track"))
        #expect(!store.isFavorite("known-false"))
        #expect(store.hasResolvedFavoriteStatus(for: "outside-page"))
        #expect(store.hasResolvedFavoriteStatus(for: "known-false"))
        #expect(store.hasResolvedFavoriteStatus(for: "first-page-track"))
    }

    @Test func `setting favorites list does not overwrite global favorite cache`() {
        let store = AppStore()

        store.updateFavoriteStatuses([
            "cached-favorite": true,
            "cached-nonfavorite": false,
        ])
        store.setSavedTrackIds(["page-track"])

        #expect(store.isFavorite("cached-favorite"))
        #expect(!store.isFavorite("cached-nonfavorite"))
        #expect(!store.isFavorite("page-track"))

        store.markTracksAsFavorite(["page-track"])

        #expect(store.isFavorite("cached-favorite"))
        #expect(!store.isFavorite("cached-nonfavorite"))
        #expect(store.isFavorite("page-track"))
    }

    /// Relinking is many-to-one, so a library page can name the same market recording twice.
    /// `markTracksAsFavorite` built a dictionary with `uniqueKeysWithValues` and trapped on
    /// the second one — a crash on opening Favorites, for any account holding a pair like it.
    @Test func `a library page naming one track twice is not a crash`() {
        let store = AppStore()

        store.setSavedTrackIds(["relinked", "other", "relinked"])
        store.markTracksAsFavorite(["relinked", "other", "relinked"])

        #expect(store.savedTrackIds == ["relinked", "other"])
        #expect(store.isFavorite("relinked"))
        #expect(store.isFavorite("other"))
    }

    /// The same collision across a page boundary, which per-page deduplication would miss.
    /// `favoriteTracks` feeds a `ForEach` keyed by track id, where a repeat is undefined
    /// behaviour rather than a repeated row.
    @Test func `a track repeated across two pages appears once`() {
        let store = AppStore()

        store.setSavedTrackIds(["a", "b"])
        store.appendSavedTrackIds(["b", "c"])

        #expect(store.savedTrackIds == ["a", "b", "c"])
    }
}
