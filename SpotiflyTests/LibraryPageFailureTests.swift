//
//  LibraryPageFailureTests.swift
//  SpotiflyTests
//
//  A library page that fails to load is recorded on the list's pagination, where every caller
//  that loads the list leaves it: the list's view, its next page, and the toolbar's refresh.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct LibraryPageFailureTests {
    @Test func `a failed page is recorded, and the next load clears it`() async {
        let store = AppStore()

        await #expect(throws: URLError.self) {
            try await store.loadLibraryPage(\.albumsPagination) { _ in throw URLError(.notConnectedToInternet) }
        }
        #expect(store.albumsPagination.failure != nil)
        #expect(!store.albumsPagination.isLoading)
        #expect(store.albumsPagination.hasMore)

        try? await store.loadLibraryPage(\.albumsPagination) { _ in (received: 2, total: 2) }
        #expect(store.albumsPagination.failure == nil)
        #expect(!store.albumsPagination.hasMore)
    }

    @Test func `a reset clears it, as a refresh starts over`() async {
        let store = AppStore()
        try? await store.loadLibraryPage(\.playlistsPagination) { _ in throw URLError(.timedOut) }

        store.playlistsPagination.reset()

        #expect(store.playlistsPagination.failure == nil)
    }

    /// A run a refresh cancelled failing is the refresh's business, not a failure to show.
    @Test func `a cancelled run records nothing`() async {
        let store = AppStore()

        try? await store.loadLibraryPage(\.favoritesPagination) { _ in throw CancellationError() }

        #expect(store.favoritesPagination.failure == nil)
    }

    /// The toolbar's refresh loads with `try?`: its failure now lands where the list reads it.
    @Test func `a refresh that fails leaves its failure for the list`() async {
        let store = AppStore()
        let service = AlbumService(store: store, partnerAPI: partnerAPI { _ in throw URLError(.notConnectedToInternet) })

        try? await service.loadUserAlbums(forceRefresh: true)

        #expect(store.albumsPagination.failure != nil)
        #expect(store.userAlbumIds.isEmpty)
    }
}
