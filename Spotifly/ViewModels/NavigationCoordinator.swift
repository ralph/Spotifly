//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Centralized navigation coordinator for app-wide navigation
//

import SwiftUI

/// Navigation destination types
enum NavigationDestination {
    case album(SearchAlbum)
    case artist(SearchArtist)
    case playlist(SearchPlaylist)
}

/// Centralized navigation coordinator that can be accessed from anywhere in the app
@MainActor
@Observable
final class NavigationCoordinator {
    /// The pending navigation destination (observed by LoggedInView)
    var pendingDestination: NavigationDestination?

    /// Counter that increments when navigation is requested (for onChange detection)
    var navigationVersion = 0

    /// Loading state for navigation requests
    var isLoading = false

    /// Error message if navigation fails
    var errorMessage: String?

    /// Navigate to an album by ID
    func navigateToAlbum(albumId: String, accessToken: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let album = try await SpotifyAPI.fetchAlbumDetails(
                    accessToken: accessToken,
                    albumId: albumId
                )
                pendingDestination = .album(album)
                navigationVersion += 1
            } catch {
                errorMessage = "Failed to load album: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Navigate to an artist by ID
    func navigateToArtist(artistId: String, accessToken: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let artist = try await SpotifyAPI.fetchArtistDetails(
                    accessToken: accessToken,
                    artistId: artistId
                )
                pendingDestination = .artist(artist)
                navigationVersion += 1
            } catch {
                errorMessage = "Failed to load artist: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Navigate to a playlist by ID
    func navigateToPlaylist(playlistId: String, accessToken: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let playlist = try await SpotifyAPI.fetchPlaylistDetails(
                    accessToken: accessToken,
                    playlistId: playlistId
                )
                pendingDestination = .playlist(playlist)
                navigationVersion += 1
            } catch {
                errorMessage = "Failed to load playlist: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Clear the pending destination (called after navigation is handled)
    func clearDestination() {
        pendingDestination = nil
    }
}
