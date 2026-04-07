//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Centralized navigation coordinator for app-wide navigation.
//  Handles cross-section navigation (sidebar jumps) and drill-down navigation stack.
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

/// Centralized navigation coordinator that can be accessed from anywhere in the app
@MainActor
@Observable
final class NavigationCoordinator {
    // MARK: - Navigation Stack

    /// Navigation path for drill-down navigation (artist, album, playlist detail views)
    var navigationPath: [NavigationDestination] = []

    /// Push a destination onto the navigation stack
    func push(_ destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    /// Clear the navigation stack (called when switching sidebar sections)
    func clearNavigationStack() {
        navigationPath = []
    }

    /// The currently active sidebar section. Updated by LoggedInView whenever
    /// the user switches sections, so any view (e.g. NowPlayingBarView) can
    /// originate cross-section navigation without needing the section threaded in.
    var currentSection: NavigationItem = .startpage

    // MARK: - Ephemeral Viewing (items not in user's library)

    /// Album being viewed that may not be in the user's library
    var viewingAlbumId: String?

    /// Artist being viewed that may not be in the user's library
    var viewingArtistId: String?

    /// Playlist being viewed that may not be in the user's library
    var viewingPlaylistId: String?

    // MARK: - Section Navigation (switches sidebar section with history)

    /// Navigate to the Albums section to view a specific album
    func navigateToAlbumSection(albumId: String, from _: NavigationItem, selectionId _: String? = nil) {
        pendingSectionNavigation = .album(albumId)
    }

    /// Navigate to the Artists section to view a specific artist
    func navigateToArtistSection(artistId: String, from _: NavigationItem, selectionId _: String? = nil) {
        pendingSectionNavigation = .artist(artistId)
    }

    /// Clear ephemeral viewing state
    func clearEphemeralViewing() {
        viewingAlbumId = nil
        viewingArtistId = nil
        viewingPlaylistId = nil
    }

    // MARK: - Cross-Section Navigation

    /// Pending cross-section navigation request (observed by LoggedInView)
    var pendingSectionNavigation: SectionNavigationRequest?

    /// Navigate to the queue
    func navigateToQueue() {
        pendingSectionNavigation = .queue
    }

    /// Navigate to the Playlists section to view a specific playlist
    func navigateToPlaylistSection(playlistId: String, from _: NavigationItem, selectionId _: String? = nil) {
        pendingSectionNavigation = .playlist(playlistId)
    }

    /// Clear the current album selection (e.g., after removal from library)
    func clearAlbumSelection() {
        viewingAlbumId = nil
    }

    /// Clear the current artist selection (e.g., after unfollowing)
    func clearArtistSelection() {
        viewingArtistId = nil
    }

    /// Clear the current playlist selection (e.g., after deletion)
    func clearPlaylistSelection() {
        viewingPlaylistId = nil
    }
}
