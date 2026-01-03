//
//  NavigationCoordinator.swift
//  Spotifly
//
//  Centralized navigation coordinator for app-wide navigation
//

import SwiftUI

/// Centralized navigation coordinator that can be accessed from anywhere in the app
@MainActor
@Observable
final class NavigationCoordinator {
    /// Current artist context (shown in sidebar when viewing artist/album)
    var currentArtist: SearchArtist?

    /// Current album within artist context
    var currentAlbum: SearchAlbum?

    /// Counter that increments when navigation is requested (for onChange detection)
    var navigationVersion = 0

    /// Loading state for navigation requests
    var isLoading = false

    /// Error message if navigation fails
    var errorMessage: String?

    /// Whether we're in artist context mode
    var isInArtistContext: Bool {
        currentArtist != nil
    }

    /// The navigation item for the sidebar
    var artistContextItem: NavigationItem? {
        guard let artist = currentArtist else { return nil }
        return .artistContext(artistName: artist.name)
    }

    /// Navigate to an artist by ID (opens artist section)
    func navigateToArtist(artistId: String, accessToken: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let artist = try await SpotifyAPI.fetchArtistDetails(
                    accessToken: accessToken,
                    artistId: artistId,
                )
                currentArtist = artist
                currentAlbum = nil
                navigationVersion += 1
            } catch {
                errorMessage = "Failed to load artist: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Navigate to an album by ID (opens album within artist context)
    func navigateToAlbum(albumId: String, accessToken: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let album = try await SpotifyAPI.fetchAlbumDetails(
                    accessToken: accessToken,
                    albumId: albumId,
                )

                // Also fetch the artist if we don't have them or it's a different artist
                let artistId = album.artistId ?? (album.artistName.isEmpty ? nil : nil)
                if let artistId, currentArtist?.id != artistId {
                    let artist = try await SpotifyAPI.fetchArtistDetails(
                        accessToken: accessToken,
                        artistId: artistId,
                    )
                    currentArtist = artist
                } else if currentArtist == nil {
                    // Create a minimal artist from album info if we can't fetch
                    // This shouldn't happen often, but handles edge cases
                    if let artistId = album.artistId {
                        let artist = try await SpotifyAPI.fetchArtistDetails(
                            accessToken: accessToken,
                            artistId: artistId,
                        )
                        currentArtist = artist
                    }
                }

                currentAlbum = album
                navigationVersion += 1
            } catch {
                errorMessage = "Failed to load album: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    /// Navigate to an album with a known artist (more efficient, avoids extra API call)
    func navigateToAlbum(_ album: SearchAlbum, artist: SearchArtist) {
        currentArtist = artist
        currentAlbum = album
        navigationVersion += 1
    }

    /// Clear the artist context (called when switching away from artist section)
    func clearArtistContext() {
        currentArtist = nil
        currentAlbum = nil
    }

    /// Clear just the current album (stay in artist context)
    func clearCurrentAlbum() {
        currentAlbum = nil
    }
}
