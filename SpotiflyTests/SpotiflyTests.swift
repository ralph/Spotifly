//
//  SpotiflyTests.swift
//  SpotiflyTests
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import Testing

@MainActor
struct SpotiflyTests {
    @Test func example() {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

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
}
