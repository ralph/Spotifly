//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Centralized navigation coordinator for app-wide navigation.
//  Handles cross-section navigation, drill-down navigation stack,
//  and back/forward history for the logged-in shell.
//

import SwiftUI

struct SectionNavigationRequest: Equatable {
    let section: NavigationItem
    let albumId: String?
    let artistId: String?
    let playlistId: String?

    static func album(_ albumId: String) -> SectionNavigationRequest {
        SectionNavigationRequest(
            section: .albums,
            albumId: albumId,
            artistId: nil,
            playlistId: nil,
        )
    }

    static func artist(_ artistId: String) -> SectionNavigationRequest {
        SectionNavigationRequest(
            section: .artists,
            albumId: nil,
            artistId: artistId,
            playlistId: nil,
        )
    }

    static func playlist(_ playlistId: String) -> SectionNavigationRequest {
        SectionNavigationRequest(
            section: .playlists,
            albumId: nil,
            artistId: nil,
            playlistId: playlistId,
        )
    }

    static let queue = SectionNavigationRequest(
        section: .queue,
        albumId: nil,
        artistId: nil,
        playlistId: nil,
    )
}

struct NavigationSnapshot: Equatable {
    var section: NavigationItem?
    var selectedAlbumId: String?
    var selectedArtistId: String?
    var selectedPlaylistId: String?
    var navigationPath: [NavigationDestination]
    var viewingAlbumId: String?
    var viewingArtistId: String?
    var viewingPlaylistId: String?
}

/// Centralized navigation coordinator that can be accessed from anywhere in the app.
@MainActor
@Observable
final class NavigationCoordinator {
    private weak var store: AppStore?

    init(store: AppStore? = nil) {
        self.store = store
    }

    func setStore(_ store: AppStore) {
        self.store = store
    }

    // MARK: - Selection State

    var selectedNavigationItem: NavigationItem? = .startpage
    var selectedAlbumId: String?
    var selectedArtistId: String?
    var selectedPlaylistId: String?

    // MARK: - Navigation Stack

    /// Navigation path for drill-down navigation (artist, album, playlist detail views).
    var navigationPath: [NavigationDestination] = []

    /// Push a destination onto the navigation stack.
    func push(_ destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    /// Clear the navigation stack (called when switching sidebar sections).
    func clearNavigationStack() {
        navigationPath = []
    }

    // MARK: - Ephemeral Viewing (items not in user's library)

    /// Album being viewed that may not be in the user's library.
    var viewingAlbumId: String?

    /// Artist being viewed that may not be in the user's library.
    var viewingArtistId: String?

    /// Playlist being viewed that may not be in the user's library.
    var viewingPlaylistId: String?

    func clearEphemeralViewing() {
        viewingAlbumId = nil
        viewingArtistId = nil
        viewingPlaylistId = nil
    }

    // MARK: - Navigation History

    private var navigationBackStack: [NavigationSnapshot] = []
    private var navigationForwardStack: [NavigationSnapshot] = []
    private var historyRestoreTarget: NavigationSnapshot?

    var currentNavigationSnapshot: NavigationSnapshot {
        NavigationSnapshot(
            section: selectedNavigationItem,
            selectedAlbumId: selectedAlbumId,
            selectedArtistId: selectedArtistId,
            selectedPlaylistId: selectedPlaylistId,
            navigationPath: navigationPath,
            viewingAlbumId: viewingAlbumId,
            viewingArtistId: viewingArtistId,
            viewingPlaylistId: viewingPlaylistId,
        )
    }

    var needsThreeColumnLayout: Bool {
        switch selectedNavigationItem {
        case .albums, .artists, .playlists:
            true
        default:
            false
        }
    }

    var canNavigateBackward: Bool {
        !navigationBackStack.isEmpty
    }

    var canNavigateForward: Bool {
        !navigationForwardStack.isEmpty
    }

    var backNavigationTitle: String? {
        navigationBackStack.last.map(title(for:))
    }

    var forwardNavigationTitle: String? {
        navigationForwardStack.last.map(title(for:))
    }

    var canRefreshCurrentSection: Bool {
        switch selectedNavigationItem {
        case .playlists, .albums, .artists, .favorites, .speakers, .queue:
            true
        default:
            false
        }
    }

    // MARK: - Section Navigation

    /// Pending cross-section navigation request (observed by LoggedInView).
    var pendingSectionNavigation: SectionNavigationRequest?

    func selectNavigationItem(_ newValue: NavigationItem?) {
        let oldValue = selectedNavigationItem
        guard oldValue != newValue else { return }

        clearNavigationStack()

        if oldValue == .albums, newValue != .albums {
            viewingAlbumId = nil
        }
        if oldValue == .artists, newValue != .artists {
            viewingArtistId = nil
        }
        if oldValue == .playlists, newValue != .playlists {
            viewingPlaylistId = nil
        }

        selectedNavigationItem = newValue
    }

    func applySectionNavigationRequest(_ request: SectionNavigationRequest) {
        viewingAlbumId = request.albumId
        viewingArtistId = request.artistId
        viewingPlaylistId = request.playlistId

        if let albumId = request.albumId {
            selectedAlbumId = albumId
        }
        if let artistId = request.artistId {
            selectedArtistId = artistId
        }
        if let playlistId = request.playlistId {
            selectedPlaylistId = playlistId
        }

        // Always clear the navigation stack when navigating to a specific item,
        // even if we're already on the same section. selectNavigationItem skips
        // clearNavigationStack() when the section hasn't changed.
        clearNavigationStack()
        selectNavigationItem(request.section)
    }

    /// Navigate to the Albums section to view a specific album.
    func navigateToAlbumSection(albumId: String) {
        pendingSectionNavigation = .album(albumId)
    }

    /// Navigate to the Artists section to view a specific artist.
    func navigateToArtistSection(artistId: String) {
        pendingSectionNavigation = .artist(artistId)
    }

    /// Navigate to the Playlists section to view a specific playlist.
    func navigateToPlaylistSection(playlistId: String) {
        pendingSectionNavigation = .playlist(playlistId)
    }

    /// Navigate to the queue.
    func navigateToQueue() {
        pendingSectionNavigation = .queue
    }

    func navigateBackward() {
        guard let previousSnapshot = navigationBackStack.popLast() else { return }
        navigationForwardStack.append(currentNavigationSnapshot)
        applyNavigationSnapshot(previousSnapshot)
    }

    func navigateForward() {
        guard let nextSnapshot = navigationForwardStack.popLast() else { return }
        navigationBackStack.append(currentNavigationSnapshot)
        applyNavigationSnapshot(nextSnapshot)
    }

    func recordNavigationChange(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) {
        if let historyRestoreTarget {
            if newValue == historyRestoreTarget {
                self.historyRestoreTarget = nil
            }
            return
        }

        guard shouldRecordNavigationChange(from: oldValue, to: newValue) else { return }

        navigationBackStack.append(oldValue)
        if navigationBackStack.count > 100 {
            navigationBackStack.removeFirst(navigationBackStack.count - 100)
        }
        navigationForwardStack.removeAll()
    }

    func pruneSearchHistory() {
        navigationBackStack.removeAll { $0.section == .searchResults }
        navigationForwardStack.removeAll { $0.section == .searchResults }
    }

    // MARK: - Selection Helpers

    func restorePlaylistSelection(previous: String?, available: [String]) {
        restoreOrSelectFirst(previous: previous, available: available, keyPath: \.selectedPlaylistId)
    }

    func restoreAlbumSelection(previous: String?, available: [String]) {
        restoreOrSelectFirst(previous: previous, available: available, keyPath: \.selectedAlbumId)
    }

    func restoreArtistSelection(previous: String?, available: [String]) {
        restoreOrSelectFirst(previous: previous, available: available, keyPath: \.selectedArtistId)
    }

    /// Clear the current album selection (e.g., after removal from library).
    func clearAlbumSelection() {
        viewingAlbumId = nil
        restoreAlbumSelection(previous: nil, available: store?.userAlbumIds ?? [])
    }

    /// Clear the current artist selection (e.g., after unfollowing).
    func clearArtistSelection() {
        viewingArtistId = nil
        restoreArtistSelection(previous: nil, available: store?.userArtistIds ?? [])
    }

    /// Clear the current playlist selection (e.g., after deletion).
    func clearPlaylistSelection() {
        viewingPlaylistId = nil
        restorePlaylistSelection(previous: nil, available: store?.userPlaylistIds ?? [])
    }

    // MARK: - Internal History Logic

    private func applyNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        historyRestoreTarget = snapshot

        selectedAlbumId = snapshot.selectedAlbumId
        selectedArtistId = snapshot.selectedArtistId
        selectedPlaylistId = snapshot.selectedPlaylistId
        viewingAlbumId = snapshot.viewingAlbumId
        viewingArtistId = snapshot.viewingArtistId
        viewingPlaylistId = snapshot.viewingPlaylistId
        navigationPath = snapshot.navigationPath
        selectedNavigationItem = snapshot.section
    }

    private func shouldRecordNavigationChange(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) -> Bool {
        guard oldValue != newValue else { return false }
        if oldValue.section == .searchResults, store?.searchResults == nil {
            return false
        }
        return !isImplicitLibraryAutoSelection(from: oldValue, to: newValue)
    }

    private func isImplicitLibraryAutoSelection(from oldValue: NavigationSnapshot, to newValue: NavigationSnapshot) -> Bool {
        guard oldValue.section == newValue.section,
              oldValue.navigationPath == newValue.navigationPath,
              oldValue.viewingAlbumId == newValue.viewingAlbumId,
              oldValue.viewingArtistId == newValue.viewingArtistId,
              oldValue.viewingPlaylistId == newValue.viewingPlaylistId
        else {
            return false
        }

        switch newValue.section {
        case .albums:
            return oldValue.selectedAlbumId == nil &&
                newValue.selectedAlbumId != nil &&
                oldValue.selectedArtistId == newValue.selectedArtistId &&
                oldValue.selectedPlaylistId == newValue.selectedPlaylistId
        case .artists:
            return oldValue.selectedArtistId == nil &&
                newValue.selectedArtistId != nil &&
                oldValue.selectedAlbumId == newValue.selectedAlbumId &&
                oldValue.selectedPlaylistId == newValue.selectedPlaylistId
        case .playlists:
            return oldValue.selectedPlaylistId == nil &&
                newValue.selectedPlaylistId != nil &&
                oldValue.selectedAlbumId == newValue.selectedAlbumId &&
                oldValue.selectedArtistId == newValue.selectedArtistId
        default:
            return false
        }
    }

    private func title(for snapshot: NavigationSnapshot) -> String {
        if let destination = snapshot.navigationPath.last {
            switch destination {
            case let .artist(id):
                return store?.artists[id]?.name ?? NavigationItem.artists.title
            case let .album(id):
                return store?.albums[id]?.name ?? NavigationItem.albums.title
            case let .playlist(id):
                return store?.playlists[id]?.name ?? NavigationItem.playlists.title
            case .searchTracks:
                return String(localized: "section.tracks")
            }
        }

        switch snapshot.section {
        case .albums:
            if let albumId = snapshot.selectedAlbumId, let album = store?.albums[albumId] {
                return album.name
            }
            return NavigationItem.albums.title
        case .artists:
            if let artistId = snapshot.selectedArtistId, let artist = store?.artists[artistId] {
                return artist.name
            }
            return NavigationItem.artists.title
        case .playlists:
            if let playlistId = snapshot.selectedPlaylistId, let playlist = store?.playlists[playlistId] {
                return playlist.name
            }
            return NavigationItem.playlists.title
        case let section?:
            return section.title
        case nil:
            return String(localized: "app.name")
        }
    }

    private func restoreOrSelectFirst(
        previous: String?,
        available: [String],
        keyPath: ReferenceWritableKeyPath<NavigationCoordinator, String?>,
    ) {
        if let previous, available.contains(previous) {
            self[keyPath: keyPath] = previous
        } else {
            self[keyPath: keyPath] = available.first
        }
    }
}
