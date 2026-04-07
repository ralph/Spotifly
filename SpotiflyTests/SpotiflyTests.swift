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

    @Test func `section switch records back history correctly`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        let oldSnapshot = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.albums)
        let newSnapshot = coordinator.currentNavigationSnapshot

        coordinator.recordNavigationChange(from: oldSnapshot, to: newSnapshot)

        #expect(coordinator.selectedNavigationItem == .albums)
        #expect(coordinator.canNavigateBackward)
        #expect(!coordinator.canNavigateForward)
        #expect(coordinator.backNavigationTitle == NavigationItem.startpage.title)
    }

    @Test func `back and forward restore snapshots without re-recording`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        let startSnapshot = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.albums)
        let albumsSnapshot = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: startSnapshot, to: albumsSnapshot)

        let beforeBack = coordinator.currentNavigationSnapshot
        coordinator.navigateBackward()
        let afterBack = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: beforeBack, to: afterBack)

        #expect(coordinator.selectedNavigationItem == .startpage)
        #expect(!coordinator.canNavigateBackward)
        #expect(coordinator.canNavigateForward)
        #expect(coordinator.forwardNavigationTitle == NavigationItem.albums.title)

        let beforeForward = coordinator.currentNavigationSnapshot
        coordinator.navigateForward()
        let afterForward = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: beforeForward, to: afterForward)

        #expect(coordinator.selectedNavigationItem == .albums)
        #expect(coordinator.canNavigateBackward)
        #expect(!coordinator.canNavigateForward)
        #expect(coordinator.backNavigationTitle == NavigationItem.startpage.title)
    }

    @Test func `implicit first library selection does not create a bogus history entry`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        let startSnapshot = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.albums)
        let albumsSnapshot = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: startSnapshot, to: albumsSnapshot)

        let beforeAutoSelection = coordinator.currentNavigationSnapshot
        coordinator.selectedAlbumId = "album-1"
        let afterAutoSelection = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: beforeAutoSelection, to: afterAutoSelection)

        let beforeBack = coordinator.currentNavigationSnapshot
        coordinator.navigateBackward()
        let afterBack = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: beforeBack, to: afterBack)

        #expect(coordinator.selectedNavigationItem == .startpage)
        #expect(!coordinator.canNavigateBackward)
        #expect(coordinator.canNavigateForward)
    }

    @Test func `clearing search prunes search history entries`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        store.searchResults = SearchResults(
            albums: [],
            artists: [],
            playlists: [],
            tracks: [],
        )

        let startSnapshot = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.searchResults)
        let searchSnapshot = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: startSnapshot, to: searchSnapshot)

        #expect(coordinator.canNavigateBackward)

        store.clearSearch()
        coordinator.pruneSearchHistory()

        let beforeLeavingSearch = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.startpage)
        let afterLeavingSearch = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: beforeLeavingSearch, to: afterLeavingSearch)

        #expect(!coordinator.canNavigateBackward)
        #expect(!coordinator.canNavigateForward)
    }

    @Test func `favorites selection clears drill down state and still records section history`() {
        let store = AppStore()
        let coordinator = NavigationCoordinator(store: store)

        coordinator.selectNavigationItem(.albums)
        coordinator.selectedAlbumId = "album-1"
        coordinator.viewingAlbumId = "album-1"
        coordinator.navigationPath = [.artist(id: "artist-1")]

        let albumsSnapshot = coordinator.currentNavigationSnapshot
        coordinator.selectNavigationItem(.favorites)
        let favoritesSnapshot = coordinator.currentNavigationSnapshot
        coordinator.recordNavigationChange(from: albumsSnapshot, to: favoritesSnapshot)

        #expect(coordinator.selectedNavigationItem == .favorites)
        #expect(coordinator.navigationPath.isEmpty)
        #expect(coordinator.viewingAlbumId == nil)
        #expect(coordinator.canNavigateBackward)
        #expect(coordinator.backNavigationTitle == NavigationItem.albums.title)
        #expect(coordinator.canRefreshCurrentSection)
    }
}
