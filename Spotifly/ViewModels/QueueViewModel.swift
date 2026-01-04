//
//  QueueViewModel.swift
//  Spotifly
//
//  Manages current playback queue state
//

import SwiftUI

@MainActor
@Observable
final class QueueViewModel {
    var queueItems: [QueueItem] = []
    var favoriteStatus: [String: Bool] = [:]
    var errorMessage: String?

    func loadQueue() {
        errorMessage = nil

        // If Spotify Connect is active, use the queue from PlaybackViewModel
        let playbackViewModel = PlaybackViewModel.shared
        if playbackViewModel.isSpotifyConnectActive {
            queueItems = playbackViewModel.spotifyConnectQueue.map { track in
                QueueItem(
                    id: track.id,
                    uri: track.uri,
                    trackName: track.name,
                    artistName: track.artistName,
                    albumArtURL: track.imageURL?.absoluteString ?? "",
                    durationMs: UInt32(track.durationMs),
                    albumId: nil,
                    artistId: nil,
                    externalUrl: nil
                )
            }
            return
        }

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadQueueAsync(accessToken: String) async {
        errorMessage = nil

        let playbackViewModel = PlaybackViewModel.shared
        if playbackViewModel.isSpotifyConnectActive {
            // Fetch fresh queue from Spotify API
            do {
                let queueResponse = try await SpotifyAPI.fetchQueue(accessToken: accessToken)
                queueItems = queueResponse.queue.map { track in
                    QueueItem(
                        id: track.id,
                        uri: track.uri,
                        trackName: track.name,
                        artistName: track.artistName,
                        albumArtURL: track.imageURL?.absoluteString ?? "",
                        durationMs: UInt32(track.durationMs),
                        albumId: nil,
                        artistId: nil,
                        externalUrl: nil
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        do {
            queueItems = try SpotifyPlayer.getAllQueueItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Batch fetch favorite status for all queue items
    func loadFavorites(accessToken: String) async {
        // Extract track IDs from URIs
        let trackIds = queueItems.compactMap { item -> String? in
            let uri = item.uri
            if uri.hasPrefix("spotify:track:") {
                return String(uri.dropFirst("spotify:track:".count))
            }
            return nil
        }

        guard !trackIds.isEmpty else { return }

        do {
            favoriteStatus = try await SpotifyAPI.checkSavedTracks(
                accessToken: accessToken,
                trackIds: trackIds,
            )
        } catch {
            // Silently fail - favorites just won't show
        }
    }

    /// Check if a track is favorited (by track ID)
    func isFavorited(trackId: String) -> Bool {
        favoriteStatus[trackId] ?? false
    }

    /// Update favorite status locally (after toggle)
    func setFavorited(trackId: String, value: Bool) {
        favoriteStatus[trackId] = value
    }

    func refresh() {
        loadQueue()
    }
}
