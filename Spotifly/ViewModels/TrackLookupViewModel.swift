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
    var trackURI: String = ""
    var isLoading = false
    var trackMetadata: TrackMetadata?
    var errorMessage: String?

    func clearInput() {
        trackURI = ""
        trackMetadata = nil
        errorMessage = nil
    }

    func lookupTrack(accessToken: String) {
        guard !trackURI.isEmpty else {
            errorMessage = "Please enter a Spotify track URI"
            return
        }

        guard let trackId = SpotifyAPI.parseTrackURI(trackURI) else {
            errorMessage = "Invalid Spotify URI format. Use spotify:track:ID or a Spotify URL"
            return
        }

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
    }
}
