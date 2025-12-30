//
//  TrackLookupViewModel.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class TrackLookupViewModel {
    var spotifyURI: String = ""
    var isLoading = false
    var trackMetadata: TrackMetadata?
    var errorMessage: String?

    func clearInput() {
        spotifyURI = ""
        trackMetadata = nil
        errorMessage = nil
    }

    func lookupTrack(accessToken: String) {
        guard !spotifyURI.isEmpty else {
            errorMessage = "Please enter a Spotify URI or URL"
            return
        }

        // Try to parse as track URI for metadata lookup
        if let trackId = SpotifyAPI.parseTrackURI(spotifyURI) {
            isLoading = true
            errorMessage = nil
            trackMetadata = nil

            Task {
                do {
                    let metadata = try await SpotifyAPI.fetchTrackMetadata(trackId: trackId, accessToken: accessToken)
                    self.trackMetadata = metadata
                    self.isLoading = false
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        } else {
            // For non-track URIs (album/playlist/artist), we won't fetch metadata
            // but we'll allow playback
            trackMetadata = nil
        }
    }
}
