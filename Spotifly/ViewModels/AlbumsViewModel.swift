//
//  AlbumsViewModel.swift
//  Spotifly
//
//  Manages user's saved albums state and loading
//

import SwiftUI

@MainActor
@Observable
final class AlbumsViewModel {
    var albums: [AlbumSimplified] = []
    var isLoading = false
    var errorMessage: String?
    var hasMore = false
    private var currentOffset = 0
    private var totalAlbums = 0

    func loadAlbums(accessToken: String) async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserAlbums(
                accessToken: accessToken,
                limit: 50,
                offset: 0,
            )

            albums = response.albums
            totalAlbums = response.total
            hasMore = response.hasMore
            currentOffset = response.nextOffset ?? 0
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMoreIfNeeded(accessToken: String) async {
        guard hasMore, !isLoading else { return }

        isLoading = true

        do {
            let response = try await SpotifyAPI.fetchUserAlbums(
                accessToken: accessToken,
                limit: 50,
                offset: currentOffset,
            )

            albums.append(contentsOf: response.albums)
            hasMore = response.hasMore
            currentOffset = response.nextOffset ?? currentOffset
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func refresh(accessToken: String) async {
        currentOffset = 0
        hasMore = false
        await loadAlbums(accessToken: accessToken)
    }
}
