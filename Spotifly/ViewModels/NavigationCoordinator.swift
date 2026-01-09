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

    // MARK: - Drill-Down Navigation

    /// Navigate to an artist detail view (pushes onto navigation stack)
    func navigateToArtist(artistId: String) {
        push(.artist(id: artistId))
    }

    /// Navigate to an album detail view (pushes onto navigation stack)
    func navigateToAlbum(albumId: String) {
        push(.album(id: albumId))
    }

    // MARK: - Cross-Section Navigation

    /// Pending navigation request (observed by LoggedInView)
    var pendingNavigationItem: NavigationItem?

    /// Pending playlist to show in detail view
    var pendingPlaylist: SearchPlaylist?

    /// Navigate to the queue
    func navigateToQueue() {
        pendingNavigationItem = .queue
    }

    /// Navigate to a playlist detail view
    func navigateToPlaylist(_ playlist: SearchPlaylist) {
        pendingPlaylist = playlist
        pendingNavigationItem = .playlists
    }

    /// Clear the current playlist selection (e.g., after deletion)
    func clearPlaylistSelection() {
        pendingPlaylist = nil
    }
}
