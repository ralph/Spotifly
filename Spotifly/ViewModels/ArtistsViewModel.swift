//
//  ArtistsViewModel.swift
//  Spotifly
//
//  Manages user's followed artists state and loading
//

import SwiftUI

@MainActor
@Observable
final class ArtistsViewModel {
    var artists: [ArtistSimplified] = []
    var isLoading = false
    var errorMessage: String?
    var hasMore = false
    private var afterCursor: String?
    private var totalArtists = 0

    func loadArtists(accessToken: String) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserArtists(
                accessToken: accessToken,
                limit: 50,
                after: nil,
            )

            artists = response.artists
            totalArtists = response.total
            hasMore = response.hasMore
            // For artists, we use the last artist's ID as cursor
            afterCursor = response.artists.last?.id
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreIfNeeded(accessToken: String) async {
        guard hasMore, !isLoading, let cursor = afterCursor else { return }

        isLoading = true

        do {
            let response = try await SpotifyAPI.fetchUserArtists(
                accessToken: accessToken,
                limit: 50,
                after: cursor,
            )

            artists.append(contentsOf: response.artists)
            hasMore = response.hasMore
            afterCursor = response.artists.last?.id
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refresh(accessToken: String) async {
        afterCursor = nil
        hasMore = false
        await loadArtists(accessToken: accessToken)
    }
}
