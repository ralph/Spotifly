//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Owns the logged-in shell's current route and back/forward history.
//

import SwiftUI

/// Centralized navigation coordinator that can be accessed from anywhere in the app.
@MainActor
@Observable
final class NavigationCoordinator {
    static let historyLimit = 100

    private weak var store: AppStore?
    private var lastSelection: [NavigationItem: Selection] = [:]
    private var historyRestoreTarget: Route?

    private(set) var current: Route = .startpage
    private(set) var back: [Route] = []
    private(set) var forward: [Route] = []

    init(store: AppStore? = nil) {
        self.store = store
    }

    func setStore(_ store: AppStore) {
        self.store = store
        noteRouteDisplayed(current)
    }

    // MARK: - Route Projections

    var selectedNavigationItem: NavigationItem? {
        get { current.section }
        set { selectNavigationItem(newValue) }
    }

    var selectedAlbumId: String? {
        get {
            guard case let .album(id) = current.selection else { return nil }
            return id
        }
        set { selectAlbum(newValue) }
    }

    var selectedArtistId: String? {
        get {
            guard case let .artist(id) = current.selection else { return nil }
            return id
        }
        set { selectArtist(newValue) }
    }

    var selectedPlaylistId: String? {
        get {
            guard case let .playlist(id) = current.selection else { return nil }
            return id
        }
        set { selectPlaylist(newValue) }
    }

    /// An entity is ephemeral only as a presentation detail. Membership never forms
    /// part of the route or its history identity.
    var viewingAlbumId: String? {
        guard let id = selectedAlbumId, store?.userAlbumIds.contains(id) != true else { return nil }
        return id
    }

    var viewingArtistId: String? {
        guard let id = selectedArtistId, store?.userArtistIds.contains(id) != true else { return nil }
        return id
    }

    var viewingPlaylistId: String? {
        guard let id = selectedPlaylistId, store?.userPlaylistIds.contains(id) != true else { return nil }
        return id
    }

    var navigationPath: [NavigationDestination] {
        get { current.path }
        set { setNavigationPath(newValue) }
    }

    var displayedSearchQuery: String? {
        current.section == .searchResults ? current.query : nil
    }

    var needsThreeColumnLayout: Bool {
        switch current.section {
        case .albums, .artists, .playlists:
            true
        default:
            false
        }
    }

    var canNavigateBackward: Bool {
        !back.isEmpty
    }

    var canNavigateForward: Bool {
        !forward.isEmpty
    }

    var backNavigationTitle: String? {
        back.last.map(title(for:))
    }

    var forwardNavigationTitle: String? {
        forward.last.map(title(for:))
    }

    var canRefreshCurrentSection: Bool {
        switch current.section {
        case .playlists, .albums, .artists, .favorites, .speakers, .queue:
            true
        default:
            false
        }
    }

    // MARK: - Navigation

    func selectNavigationItem(_ section: NavigationItem?) {
        let route: Route

        switch section {
        case .albums, .artists, .playlists:
            route = Route(
                section: section,
                selection: section.flatMap { lastSelection[$0] },
                query: nil,
                path: [],
            )
        case .searchResults:
            guard let query = store?.lastDisplayedSearchQuery,
                  store?.searchResults(for: query) != nil
            else {
                return
            }
            route = Route(section: .searchResults, selection: nil, query: query, path: [])
        default:
            route = Route(section: section, selection: nil, query: nil, path: [])
        }

        navigate(to: route)
    }

    func navigateToSearchResults(query: String) {
        guard store?.searchResults(for: query) != nil else { return }
        navigate(to: Route(section: .searchResults, selection: nil, query: query, path: []))
    }

    func selectAlbum(_ albumId: String?, recordsHistory: Bool = true) {
        setSelection(albumId.map { .album(id: $0) }, for: .albums, recordsHistory: recordsHistory)
    }

    func selectArtist(_ artistId: String?, recordsHistory: Bool = true) {
        setSelection(artistId.map { .artist(id: $0) }, for: .artists, recordsHistory: recordsHistory)
    }

    func selectPlaylist(_ playlistId: String?, recordsHistory: Bool = true) {
        setSelection(playlistId.map { .playlist(id: $0) }, for: .playlists, recordsHistory: recordsHistory)
    }

    /// Push a destination onto the drill-down path.
    func push(_ destination: NavigationDestination) {
        setNavigationPath(current.path + [destination])
    }

    /// Classifies writes from `NavigationStack`: extensions are pushes, prefixes are
    /// native pops through shared history, and replacements are new locations.
    func setNavigationPath(_ newPath: [NavigationDestination]) {
        if let historyRestoreTarget, newPath == historyRestoreTarget.path {
            self.historyRestoreTarget = nil
            return
        }

        let oldPath = current.path
        guard newPath != oldPath else { return }

        var route = current
        route.path = newPath

        if newPath.starts(with: oldPath) {
            navigate(to: route)
        } else if oldPath.starts(with: newPath) {
            navigateBackward(to: route)
        } else {
            navigate(to: route)
        }
    }

    /// Clear the visible drill-down as a new location.
    func clearNavigationStack() {
        setNavigationPath([])
    }

    /// Navigate directly to the Albums section and a specific album.
    func navigateToAlbumSection(albumId: String) {
        navigateToSection(.albums, selection: .album(id: albumId))
    }

    /// Navigate directly to the Artists section and a specific artist.
    func navigateToArtistSection(artistId: String) {
        navigateToSection(.artists, selection: .artist(id: artistId))
    }

    /// Navigate directly to the Playlists section and a specific playlist.
    func navigateToPlaylistSection(playlistId: String) {
        navigateToSection(.playlists, selection: .playlist(id: playlistId))
    }

    /// Navigate directly to the queue.
    func navigateToQueue() {
        selectNavigationItem(.queue)
    }

    func navigateBackward() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        restore(previous)
    }

    func navigateForward() {
        guard let next = forward.popLast() else { return }
        appendToBack(current)
        restore(next)
    }

    // MARK: - Selection Helpers

    func restorePlaylistSelection(previous: String?, available: [String]) {
        selectPlaylist(restoredSelection(previous: previous, available: available), recordsHistory: false)
    }

    func restoreAlbumSelection(previous: String?, available: [String]) {
        selectAlbum(restoredSelection(previous: previous, available: available), recordsHistory: false)
    }

    func restoreArtistSelection(previous: String?, available: [String]) {
        selectArtist(restoredSelection(previous: previous, available: available), recordsHistory: false)
    }

    /// Select the first remaining album without adding an automatic history step.
    func clearAlbumSelection() {
        selectAlbum(store?.userAlbumIds.first, recordsHistory: false)
    }

    /// Select the first remaining artist without adding an automatic history step.
    func clearArtistSelection() {
        selectArtist(store?.userArtistIds.first, recordsHistory: false)
    }

    /// Remove deleted playlist routes from the complete history sequence.
    func clearPlaylistSelection() {
        invalidateUnviewableRoutes()
    }

    // MARK: - Invalidation

    /// Removes every unviewable route from the full chronological history, collapses
    /// equal adjacent runs, then rebuilds back/current/forward around the survivor.
    func invalidateUnviewableRoutes() {
        lastSelection = lastSelection.filter { _, selection in
            store?.deletedEntitySelections.contains(selection) != true
        }

        let chronological = back + [current] + forward.reversed()
        let oldCurrentIndex = back.count

        let surviving = chronological.enumerated().compactMap { index, route in
            isViewable(route) ? IndexedRoute(route: route, originalIndices: [index]) : nil
        }
        let collapsed = surviving.reduce(into: [IndexedRoute]()) { result, entry in
            if result.last?.route == entry.route {
                result[result.count - 1].originalIndices.append(contentsOf: entry.originalIndices)
            } else {
                result.append(entry)
            }
        }

        guard !collapsed.isEmpty else {
            back = []
            forward = []
            restore(.startpage)
            return
        }

        let currentGroupIndex = collapsed.firstIndex { $0.originalIndices.contains(oldCurrentIndex) }
            ?? collapsed.lastIndex { entry in
                entry.originalIndices.contains { $0 < oldCurrentIndex }
            }
            ?? collapsed.startIndex

        back = collapsed[..<currentGroupIndex].map(\.route)
        current = collapsed[currentGroupIndex].route
        forward = collapsed[(currentGroupIndex + 1)...].map(\.route).reversed()
        historyRestoreTarget = current
        rememberSelection(from: current)
        noteRouteDisplayed(current)
    }

    // MARK: - Internal History Logic

    private struct IndexedRoute {
        var route: Route
        var originalIndices: [Int]
    }

    private func navigateToSection(_ section: NavigationItem, selection: Selection) {
        lastSelection[section] = selection
        navigate(to: Route(section: section, selection: selection, query: nil, path: []))
    }

    private func setSelection(_ selection: Selection?, for section: NavigationItem, recordsHistory: Bool) {
        guard current.section == section else { return }

        if let selection {
            lastSelection[section] = selection
        } else {
            lastSelection.removeValue(forKey: section)
        }

        var route = current
        route.selection = selection
        if recordsHistory {
            navigate(to: route)
        } else {
            replace(with: route)
        }
    }

    private func navigate(to route: Route) {
        historyRestoreTarget = nil
        guard route != current else {
            rememberSelection(from: route)
            noteRouteDisplayed(route)
            return
        }

        appendToBack(current)
        current = route
        forward.removeAll()
        rememberSelection(from: route)
        noteRouteDisplayed(route)
    }

    private func replace(with route: Route) {
        guard route != current else { return }
        historyRestoreTarget = route
        current = route
        while back.last == current {
            back.removeLast()
        }
        while forward.last == current {
            forward.removeLast()
        }
        rememberSelection(from: route)
        noteRouteDisplayed(route)
    }

    private func restore(_ route: Route) {
        historyRestoreTarget = route
        current = route
        rememberSelection(from: route)
        noteRouteDisplayed(route)
    }

    private func navigateBackward(to target: Route) {
        guard let targetIndex = back.lastIndex(of: target) else {
            navigate(to: target)
            return
        }

        while back.indices.contains(targetIndex), current != target {
            navigateBackward()
        }
    }

    private func appendToBack(_ route: Route) {
        back.append(route)
        if back.count > Self.historyLimit {
            back.removeFirst(back.count - Self.historyLimit)
        }
    }

    private func rememberSelection(from route: Route) {
        guard let section = route.section, let selection = route.selection else { return }
        lastSelection[section] = selection
    }

    private func noteRouteDisplayed(_ route: Route) {
        guard route.section == .searchResults, let query = route.query else { return }
        store?.markSearchQueryDisplayed(query)
    }

    private func restoredSelection(previous: String?, available: [String]) -> String? {
        if let previous, available.contains(previous) {
            previous
        } else {
            available.first
        }
    }

    private func isViewable(_ route: Route) -> Bool {
        if route.section == .searchResults {
            guard let query = route.query, store?.searchResults(for: query) != nil else { return false }
        }

        if let selection = route.selection, store?.deletedEntitySelections.contains(selection) == true {
            return false
        }

        return !route.path.contains { destination in
            guard case let .playlist(id) = destination else { return false }
            return store?.deletedEntitySelections.contains(.playlist(id: id)) == true
        }
    }

    private func title(for route: Route) -> String {
        if let destination = route.path.last {
            switch destination {
            case let .artist(id):
                return store?.artists[id]?.name ?? route.section?.title ?? String(localized: "app.name")
            case let .album(id):
                return store?.albums[id]?.name ?? route.section?.title ?? String(localized: "app.name")
            case let .playlist(id):
                return store?.playlists[id]?.name ?? route.section?.title ?? String(localized: "app.name")
            case .searchTracks:
                return String(localized: "section.tracks")
            }
        }

        switch route.selection {
        case let .album(id):
            return store?.albums[id]?.name ?? route.section?.title ?? NavigationItem.albums.title
        case let .artist(id):
            return store?.artists[id]?.name ?? route.section?.title ?? NavigationItem.artists.title
        case let .playlist(id):
            return store?.playlists[id]?.name ?? route.section?.title ?? NavigationItem.playlists.title
        case nil:
            return route.section?.title ?? String(localized: "app.name")
        }
    }
}
