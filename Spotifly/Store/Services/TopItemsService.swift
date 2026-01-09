//
//  TopItemsService.swift
//  Spotifly
//
//  Service for fetching user's top artists and tracks.
//  Fetches data from API and stores entities in AppStore.
//

import Foundation

@MainActor
@Observable
final class TopItemsService {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Top Artists

    /// Load top artists (only on first call unless refresh is called)
    func loadTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard !store.hasLoadedTopArtists else { return }
        store.hasLoadedTopArtists = true
        await refreshTopArtists(accessToken: accessToken, timeRange: timeRange)
    }

    /// Force refresh top artists
    func refreshTopArtists(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topArtistsIsLoading = true
        store.topArtistsErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserTopArtists(
                accessToken: accessToken,
                timeRange: timeRange,
                limit: 20,
            )

            // Convert to entities and store
            let artists = response.artists.map { Artist(from: $0) }
            store.upsertArtists(artists)
            store.setTopArtistIds(artists.map(\.id))

        } catch {
            store.topArtistsErrorMessage = error.localizedDescription
        }

        store.topArtistsIsLoading = false
    }

    // MARK: - Top Tracks

    /// Load top tracks (only on first call unless refresh is called)
    func loadTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        guard !store.hasLoadedTopTracks else { return }
        store.hasLoadedTopTracks = true
        await refreshTopTracks(accessToken: accessToken, timeRange: timeRange)
    }

    /// Force refresh top tracks
    func refreshTopTracks(accessToken: String, timeRange: TopItemsTimeRange = .mediumTerm) async {
        store.topTracksIsLoading = true
        store.topTracksErrorMessage = nil

        do {
            let response = try await SpotifyAPI.fetchUserTopTracks(
                accessToken: accessToken,
                timeRange: timeRange,
                limit: 20,
            )

            // Convert to entities and store
            let tracks = response.tracks.map { Track(from: $0) }
            store.upsertTracks(tracks)
            store.setTopTrackIds(tracks.map(\.id))

        } catch {
            store.topTracksErrorMessage = error.localizedDescription
        }

        store.topTracksIsLoading = false
    }
}
