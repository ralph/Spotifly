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
            route = Route(section: section, selection: section.flatMap { lastSelection[$0] })
        case .searchResults:
            guard let query = store?.lastDisplayedSearchQuery,
                  store?.searchResults(for: query) != nil
            else {
                return
            }
            route = Route(section: .searchResults, query: query)
        default:
            route = Route(section: section)
        }

        navigate(to: route)
    }

    func navigateToSearchResults(query: String) {
        guard store?.searchResults(for: query) != nil else { return }
        navigate(to: Route(section: .searchResults, query: query))
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

        // A shorter path that the old one starts with is `NavigationStack`'s own back
        // chevron, which has to move through the shared history — recording it would put
        // the view just left onto the back stack. An extension is a push and anything else
        // is a jump; both are new locations.
        if oldPath.starts(with: newPath) {
            navigateBackward(to: route)
        } else {
            navigate(to: route)
        }
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

        // Runs of *adjacent* equal routes collapse, never duplicates elsewhere in the
        // sequence: revisiting a place is a real step and has to stay replayable.
        let runs = chronological.enumerated()
            .filter { isViewable($0.element) }
            .reduce(into: [RouteRun]()) { runs, entry in
                guard runs.last?.route != entry.element else { return }
                runs.append(RouteRun(route: entry.element, firstIndex: entry.offset))
            }

        guard !runs.isEmpty else {
            back = []
            forward = []
            restore(.startpage)
            return
        }

        // Runs stay in chronological order, so the last one starting at or before the old
        // position is either the run holding it or — if it was dropped — the nearest
        // survivor behind it.
        let currentRunIndex = runs.lastIndex { $0.firstIndex <= oldCurrentIndex } ?? runs.startIndex

        back = runs[..<currentRunIndex].map(\.route)
        current = runs[currentRunIndex].route
        forward = runs[(currentRunIndex + 1)...].map(\.route).reversed()
        historyRestoreTarget = current
        noteRouteDisplayed(current)
    }

    // MARK: - Internal History Logic

    /// A surviving route together with where its run began in the pre-collapse sequence.
    private struct RouteRun {
        var route: Route
        var firstIndex: Int
    }

    private func navigateToSection(_ section: NavigationItem, selection: Selection) {
        navigate(to: Route(section: section, selection: selection))
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
        if route != current {
            appendToBack(current)
            current = route
            forward.removeAll()
        }
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
        noteRouteDisplayed(route)
    }

    private func restore(_ route: Route) {
        historyRestoreTarget = route
        current = route
        noteRouteDisplayed(route)
    }

    private func navigateBackward(to target: Route) {
        guard let targetIndex = back.lastIndex(of: target) else {
            // A pop is a backward move even when its destination was never recorded — the
            // user can arrive deep in one step by assigning a whole path, and the levels
            // skipped on the way in were never locations. Recording it as a *new* location
            // would put the view just left onto the back stack, so Back would walk straight
            // back into it.
            // Consume any pending restore target. `replace` can have left one pointing at
            // the full path — an automatic selection while a drill-down is showing does
            // exactly that — and the write it was waiting for is this pop. Leaving it set
            // would make the next push back to that path look like a restore callback and
            // be swallowed.
            historyRestoreTarget = nil
            forward.append(current)
            // A pop can skip several levels at once, and the ones it skipped are sitting at
            // the end of the back stack — they were passed through on the way *deeper*.
            // Leaving them there would make Back walk further into the path just exited.
            // Moving them in order keeps Forward replaying the way back down.
            while let deeper = back.last, isDescendant(deeper, of: target) {
                forward.append(back.removeLast())
            }
            current = target
            noteRouteDisplayed(target)
            return
        }

        while back.indices.contains(targetIndex), current != target {
            navigateBackward()
        }
    }

    /// Whether `route` sits deeper in the same place — same section, same selection, same
    /// query, and a strictly longer path that continues the target's.
    private func isDescendant(_ route: Route, of target: Route) -> Bool {
        route.section == target.section
            && route.selection == target.selection
            && route.query == target.query
            && route.path.count > target.path.count
            && route.path.starts(with: target.path)
    }

    private func appendToBack(_ route: Route) {
        back.append(route)
        if back.count > Self.historyLimit {
            back.removeFirst(back.count - Self.historyLimit)
        }
    }

    /// Bookkeeping for a route that has just become the visible one: the selection its
    /// section reopens to, and — for a search route — the query the sidebar reopens to.
    /// Both are memos outside `Route`, so neither takes part in history identity.
    private func noteRouteDisplayed(_ route: Route) {
        if let section = route.section, let selection = route.selection {
            lastSelection[section] = selection
        }

        if route.section == .searchResults, let query = route.query {
            store?.markSearchQueryDisplayed(query)
        }
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

    /// An entity missing from the store falls back to the route's own section, never to the
    /// kind of the entity — an album route holding an artist drill-down is still in Albums,
    /// and naming it "Artists" pointed Back at a section the user was never in.
    private func title(for route: Route) -> String {
        let sectionTitle = route.section?.title ?? String(localized: "app.name")

        if let destination = route.path.last {
            switch destination {
            case .searchTracks:
                return String(localized: "section.tracks")
            case let .artist(id):
                return name(of: .artist(id: id)) ?? sectionTitle
            case let .album(id):
                return name(of: .album(id: id)) ?? sectionTitle
            case let .playlist(id):
                return name(of: .playlist(id: id)) ?? sectionTitle
            }
        }

        return route.selection.flatMap(name(of:)) ?? sectionTitle
    }

    private func name(of selection: Selection) -> String? {
        switch selection {
        case let .album(id):
            store?.albums[id]?.name
        case let .artist(id):
            store?.artists[id]?.name
        case let .playlist(id):
            store?.playlists[id]?.name
        }
    }
}
