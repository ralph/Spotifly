//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Centralized navigation coordinator for app-wide navigation.
//  Handles cross-section navigation (sidebar jumps) and drill-down navigation stack.
//

import SwiftUI

/// Centralized navigation coordinator that can be accessed from anywhere in the app
@MainActor
@Observable
final class NavigationCoordinator {
    // MARK: - Navigation Stack

    /// Navigation path for drill-down navigation (artist, album, playlist detail views)
    var navigationPath = NavigationPath()

    /// Push a destination onto the navigation stack
    func push(_ destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    /// Clear the navigation stack (called when switching sidebar sections)
    func clearNavigationStack() {
        navigationPath = NavigationPath()
    }

    // MARK: - Section History (for back navigation between sections)

    /// The section the user navigated from (for back button)
    var previousSection: NavigationItem?

    /// The selection ID in the previous section (to restore state when going back)
    var previousSelectionId: String?

    /// Title for the back button (e.g., "Playlists", "Home")
    var previousSectionTitle: String? {
        previousSection?.title
    }

    // MARK: - Ephemeral Viewing (items not in user's library)

    /// Album being viewed that may not be in the user's library
    var viewingAlbumId: String?

    /// Artist being viewed that may not be in the user's library
    var viewingArtistId: String?

    // MARK: - Drill-Down Navigation (within a section)

    /// Navigate to an artist detail view (pushes onto navigation stack)
    func navigateToArtist(artistId: String) {
        push(.artist(id: artistId))
    }

    /// Navigate to an album detail view (pushes onto navigation stack)
    func navigateToAlbum(albumId: String) {
        push(.album(id: albumId))
    }

    /// Navigate to a playlist detail view (pushes onto navigation stack)
    func navigateToPlaylistDetail(playlistId: String) {
        push(.playlist(id: playlistId))
    }

    // MARK: - Section Navigation (switches sidebar section with history)

    /// Navigate to the Albums section to view a specific album
    /// - Parameters:
    ///   - albumId: The album to view
    ///   - fromSection: The current section (for back navigation)
    ///   - selectionId: The current selection ID (playlist ID, etc.) to restore when going back
    func navigateToAlbumSection(albumId: String, from fromSection: NavigationItem, selectionId: String? = nil) {
        previousSection = fromSection
        previousSelectionId = selectionId
        viewingAlbumId = albumId
        pendingNavigationItem = .albums
    }

    /// Navigate to the Artists section to view a specific artist
    /// - Parameters:
    ///   - artistId: The artist to view
    ///   - fromSection: The current section (for back navigation)
    ///   - selectionId: The current selection ID to restore when going back
    func navigateToArtistSection(artistId: String, from fromSection: NavigationItem, selectionId: String? = nil) {
        previousSection = fromSection
        previousSelectionId = selectionId
        viewingArtistId = artistId
        pendingNavigationItem = .artists
    }

    /// Go back to the previous section
    /// - Returns: The section to navigate to, or nil if no history
    func goBack() -> (section: NavigationItem, selectionId: String?)? {
        guard let section = previousSection else { return nil }
        let selectionId = previousSelectionId
        clearSectionHistory()
        return (section, selectionId)
    }

    /// Clear section history (called when user manually navigates)
    func clearSectionHistory() {
        previousSection = nil
        previousSelectionId = nil
    }

    /// Clear ephemeral viewing state
    func clearEphemeralViewing() {
        viewingAlbumId = nil
        viewingArtistId = nil
    }

    // MARK: - Cross-Section Navigation

    /// Pending navigation request (observed by LoggedInView)
    var pendingNavigationItem: NavigationItem?

    /// Pending playlist to show in detail view
    var pendingPlaylist: Playlist?

    /// Navigate to the queue
    func navigateToQueue() {
        pendingNavigationItem = .queue
    }

    /// Navigate to a playlist detail view
    func navigateToPlaylist(_ playlist: Playlist) {
        pendingPlaylist = playlist
        pendingNavigationItem = .playlists
    }

    /// Clear the current playlist selection (e.g., after deletion)
    func clearPlaylistSelection() {
        pendingPlaylist = nil
    }
}
